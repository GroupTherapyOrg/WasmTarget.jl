------------------------------- MODULE ProvenDead -------------------------------
(***************************************************************************)
(* A TLA+ model of `stmt_is_proven_unreachable` (src/codegen/generate.jl)   *)
(* with the `analyze_blocks` it reads: the proof that a statement can never *)
(* execute. It is the sole condition under which an unsupported lowering    *)
(* may stay a diagnosed trap instead of rejecting the compilation           *)
(* (record_unsupported!, Diagnostics.tla, which takes this proof as its     *)
(* ProvenDead input) -- so a statement proven dead that CAN execute turns a *)
(* loud compile-time reject into a run-time trap.                           *)
(* parity(quarantine: Julia's typed IR is a goto CFG that can keep blocks   *)
(* no edge reaches; dart's TFA removes unreachable members before codegen,  *)
(* code_generator.dart:5084 UnreachableCodeGenerator).                      *)
(*                                                                          *)
(* WHAT THE REAL FUNCTION DOES (read from source). `analyze_blocks` cuts the *)
(* statements into basic blocks: a block ends at a goto, a goto-if-not or a *)
(* return, or just before a jump target. Then a worklist from block 1: a    *)
(* goto's successor is its target's block; a goto-if-not's are its target's *)
(* block and the next block; a block ending in anything else but a return   *)
(* falls through to the next block. A statement is proven unreachable when  *)
(* its block was never marked. (A body with a try/catch is never proven     *)
(* dead; not modeled -- it only answers false.)                             *)
(*                                                                          *)
(* THE CLAIM (Sound): a statement proven unreachable is not reachable from  *)
(* statement 1 in the statement-level control-flow graph.                   *)
(*                                                                          *)
(* WHAT IS ABSTRACTED. Statements are `goto t`, `goto t if not c`, `return` *)
(* or a plain statement; every target is a statement index. Init chooses    *)
(* every program of N statements -- the class is exhaustive at that size.   *)
(*                                                                          *)
(* VARIANT CondFallthrough: TRUE = the real worklist; FALSE = a goto-if-not *)
(* treated like a goto (its fall-through successor dropped).                *)
(*                                                                          *)
(* formal(dev/formal/ProvenDead.tla): a statement stmt_is_proven_unreachable *)
(* proves dead has no control-flow path from entry.                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS N, CondFallthrough

ASSUME N \in Nat /\ N >= 1
ASSUME CondFallthrough \in BOOLEAN

Idx == 1..N
Stmts == {[k |-> "plain"], [k |-> "return"]} \cup
         {[k |-> "goto", t |-> t] : t \in Idx} \cup {[k |-> "gotoifnot", t |-> t] : t \in Idx}
Programs == [Idx -> Stmts]

VARIABLE prog
vars == <<prog>>

IsJump(s) == s.k \in {"goto", "gotoifnot"}
IsTerm(s) == s.k \in {"goto", "gotoifnot", "return"}

\* ground truth: statement-level successors
Succ(p, i) == CASE p[i].k = "goto"      -> {p[i].t}
                [] p[i].k = "gotoifnot" -> {p[i].t} \cup (IF i < N THEN {i + 1} ELSE {})
                [] p[i].k = "return"    -> {}
                [] OTHER                -> IF i < N THEN {i + 1} ELSE {}
RECURSIVE ReachFrom(_, _)
ReachFrom(p, S) == LET nxt == S \cup UNION {Succ(p, i) : i \in S} IN IF nxt = S THEN S ELSE ReachFrom(p, nxt)
Reachable(p) == ReachFrom(p, {1})

\* analyze_blocks: a block starts at 1, after a terminator, and at every jump target; the
\* block containing statement i is the last start at or before it (block ids = start indices)
Targets(p) == {p[i].t : i \in {j \in Idx : IsJump(p[j])}}
Starts(p) == {i \in Idx : i = 1 \/ IsTerm(p[i - 1]) \/ i \in Targets(p)}
MaxOf(S) == CHOOSE m \in S : \A x \in S : x <= m
BlockMap(p) == LET st == Starts(p) IN [i \in Idx |-> MaxOf({s \in st : s <= i})]
\* the block's last statement is the one before the next start (or N)
EndMap(p, blk) == [s \in Starts(p) |-> MaxOf({e \in Idx : blk[e] = s})]

\* the worklist's successor blocks
BSucc(p, blk, end, s) ==
    LET term == p[end[s]]
        next == IF end[s] < N THEN {blk[end[s] + 1]} ELSE {}
    IN CASE term.k = "goto" -> {blk[term.t]}
         [] term.k = "gotoifnot" -> {blk[term.t]} \cup (IF CondFallthrough THEN next ELSE {})
         [] term.k = "return" -> {}
         [] OTHER -> next
RECURSIVE BReach(_, _, _, _)
BReach(p, blk, end, S) ==
    LET nxt == S \cup UNION {BSucc(p, blk, end, s) : s \in S}
    IN IF nxt = S THEN S ELSE BReach(p, blk, end, nxt)

Init == prog \in Programs
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == prog \in Programs

Sound ==
    LET blk  == BlockMap(prog)
        end  == EndMap(prog, blk)
        live == BReach(prog, blk, end, {1})
        reach == Reachable(prog)
    IN \A i \in Idx : blk[i] \notin live => i \notin reach
=============================================================================
