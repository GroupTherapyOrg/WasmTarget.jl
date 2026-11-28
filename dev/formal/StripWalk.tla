----------------------------- MODULE StripWalk -----------------------------
(***************************************************************************)
(* A TLA+ model of flisp's strip-op-suffix walk (julia/src/flisp/          *)
(* julia_extensions.c:245 fl_julia_strip_op_suffix, its characters read by *)
(* u8_nextchar, julia/src/support/utf8.c:269) against WasmTarget's port    *)
(* (src/patch/unicode.jl fl_julia_strip_op_suffix, u8_nextchar).           *)
(*                                                                         *)
(* C. The name's bytes lie in memory followed by the NUL flisp's strcpy    *)
(* stores (julia/src/flisp/flisp.c:217 mk_symbol), then bytes C leaves     *)
(* undefined (malloc padding or beyond): Garbage, any bytes. From offset 0 *)
(* the walk stops at a NUL (`while (op[i])`); else it reads a character, a *)
(* sequence of SeqLen(first byte) bytes from i, whatever those bytes are   *)
(* (the NUL and garbage included), and stops at i when it is an operator   *)
(* suffix, else moves to the offset after it. Stopped at 0 or at a NUL the *)
(* name is itself; else strncpy copies i bytes, which end at the first NUL *)
(* the copy meets, and symbol() interns that copy.                         *)
(*                                                                         *)
(* PORT. The name is a String of n bytes; a byte at an offset >= n reads   *)
(* as 0 (the NUL, and zeros for C's undefined bytes); the walk runs while  *)
(* i < n and the name is itself at i = 0 or i >= n, else its first i bytes.*)
(*                                                                         *)
(* SeqLen and the suffix predicate are abstract: SeqLen is the instance's, *)
(* the suffix set Suff any subset of the candidate tuples, among them      *)
(* tuples that end in the NUL (a sequence cut off by the name's end).      *)
(*                                                                         *)
(* THE CLAIM. A walk that stops past the NUL gives back the name itself    *)
(* (StripPastNulIsName); wherever C reads nothing past the NUL the port    *)
(* answers C's name (PortAgreesWhereDefined); and the port answers what C  *)
(* answers over zeroed garbage, so it answers C's name wherever C's answer *)
(* does not depend on the undefined bytes (PortIsZeroGarbage).             *)
(* Broken variants: ReadPolicy "ErrAtNul" (a read at offset n is a bounds  *)
(* error, the port before review 1's F1: "+\xce" threw where Julia answers *)
(* true) breaks PortAgreesWhereDefined; "ErrPastNul" (a read past n is a   *)
(* bounds error, the port before review 2's F1: "+\xe3" threw) breaks      *)
(* PortIsZeroGarbage. "ErrAtNul" breaks PortIsZeroGarbage too, so its     *)
(* instance checks the claim it is meant to break, PortAgreesWhereDefined. *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
  Bytes,        \* the nonzero byte values a name holds
  MaxLen,       \* the longest name
  GarbageLen,   \* the undefined bytes modelled after the NUL
  Cands,        \* the candidate suffix tuples
  ReadPolicy    \* the port's read at an offset >= n: "Zero", "ErrAtNul" or "ErrPastNul"
CONSTANT SeqLen(_)  \* u8_seqlen: a sequence's length by its first byte (0's is 1)

VARIABLES name, garbage, Suff
vars == <<name, garbage, Suff>>

Max(a, b) == IF a >= b THEN a ELSE b
Min(a, b) == IF a <= b THEN a ELSE b
MaxSeq == 3
Names == UNION {[1..k -> Bytes] : k \in 0..MaxLen}
Garbages == [1..GarbageLen -> Bytes \cup {0}]
ZeroGarbage == [x \in 1..GarbageLen |-> 0]

\* C's memory: the name, its NUL, the undefined bytes, then zeros enough that every walk ends
Mem(nm, g) == nm \o <<0>> \o g \o [x \in 1..MaxSeq |-> 0]
Byte(mem, k) == mem[k + 1]
Chr(mem, i) == [x \in 1..SeqLen(Byte(mem, i)) |-> Byte(mem, i + x - 1)]

\* C's walk: where it stops and the furthest offset it read
RECURSIVE CWalk(_, _, _)
CWalk(mem, i, m) ==
  IF Byte(mem, i) = 0 THEN [stop |-> i, maxread |-> Max(m, i)]
  ELSE LET L == SeqLen(Byte(mem, i)) IN
       IF Chr(mem, i) \in Suff THEN [stop |-> i, maxread |-> Max(m, i + L - 1)]
       ELSE CWalk(mem, i + L, Max(m, i + L - 1))

FirstNul(mem) == CHOOSE k \in 0..Len(mem) - 1 : Byte(mem, k) = 0 /\ \A j \in 0..k - 1 : Byte(mem, j) # 0

\* the name C's strip-op-suffix answers: itself, or the copy strncpy makes of i bytes, ending at a NUL it meets
CResult(nm, g) ==
  LET mem == Mem(nm, g)
      s == CWalk(mem, 0, 0).stop IN
  IF s = 0 \/ Byte(mem, s) = 0 THEN nm ELSE SubSeq(mem, 1, Min(s, FirstNul(mem)))

\* the port's read at offset k of a name of n bytes, and whether its policy errs there
PByte(nm, k) == IF k < Len(nm) THEN nm[k + 1] ELSE 0
ReadErr(n, k) == (ReadPolicy = "ErrAtNul" /\ k >= n) \/ (ReadPolicy = "ErrPastNul" /\ k > n)
PChr(nm, i) == [x \in 1..SeqLen(PByte(nm, i)) |-> PByte(nm, i + x - 1)]

RECURSIVE PWalk(_, _)
PWalk(nm, i) ==
  IF i >= Len(nm) THEN [stop |-> i, err |-> FALSE]
  ELSE LET L == SeqLen(PByte(nm, i)) IN
       IF \E x \in 0..L - 1 : ReadErr(Len(nm), i + x) THEN [stop |-> i, err |-> TRUE]
       ELSE IF PChr(nm, i) \in Suff THEN [stop |-> i, err |-> FALSE]
       ELSE PWalk(nm, i + L)

PResult(nm) ==
  LET w == PWalk(nm, 0) IN
  IF w.err THEN [ok |-> FALSE, name |-> <<>>]
  ELSE [ok |-> TRUE, name |-> IF w.stop = 0 \/ w.stop >= Len(nm) THEN nm ELSE SubSeq(nm, 1, w.stop)]

Init == name \in Names /\ garbage \in Garbages /\ Suff \in SUBSET Cands
\* every name, garbage and suffix set is an initial state; the check is of each: an explicit stutter
Next == UNCHANGED vars

TypeOK == name \in Names /\ garbage \in Garbages /\ Suff \subseteq Cands

StripPastNulIsName ==
  CWalk(Mem(name, garbage), 0, 0).stop > Len(name) => CResult(name, garbage) = name

PortAgreesWhereDefined ==
  CWalk(Mem(name, garbage), 0, 0).maxread <= Len(name) =>
    PResult(name) = [ok |-> TRUE, name |-> CResult(name, garbage)]

PortIsZeroGarbage == PResult(name) = [ok |-> TRUE, name |-> CResult(name, ZeroGarbage)]
=============================================================================
