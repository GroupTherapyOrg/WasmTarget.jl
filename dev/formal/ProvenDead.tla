------------------------------- MODULE ProvenDead -------------------------------
(***************************************************************************)
(* A TLA+ model of `stmt_is_proven_unreachable` (src/codegen/generate.jl)   *)
(* with the `nir_cfg` it reads: the proof that a statement can never        *)
(* execute. It is the sole condition under which an unsupported lowering    *)
(* may stay a diagnosed trap instead of rejecting the compilation           *)
(* (record_unsupported!, Diagnostics.tla, which takes this proof as its     *)
(* ProvenDead input) -- so a statement proven dead that CAN execute turns a *)
(* loud compile-time reject into a run-time trap.                           *)
(* parity(quarantine: Julia's typed IR is a goto CFG that can keep blocks   *)
(* no edge reaches; dart's TFA removes unreachable members before codegen,  *)
(* code_generator.dart:5084 UnreachableCodeGenerator).                      *)
(*                                                                          *)
(* WHAT THE REAL FUNCTION DOES (read from source). `nir_cfg` cuts the       *)
(* statements into basic blocks by Julia's own rule (Compiler ir.jl:46      *)
(* basic_blocks_starts, :93 compute_basic_blocks): a block starts at 1,     *)
(* after a goto, a goto-if-not, a return or a :leave, at an Enter and after *)
(* it, at every jump target and at every catch destination. A goto's        *)
(* successor is its target's block; a goto-if-not's are its target's block  *)
(* and the next; an Enter's are its catch destination's block (the catch    *)
(* edge) and the next; any other block but a return's falls through. Then a *)
(* worklist from block 1; a statement is proven unreachable when its block  *)
(* was never marked. (A phi whose edge is the statement before it also      *)
(* starts a block in Julia's rule; no statement here is a phi, and the      *)
(* split only refines a block reached by fall-through.)                     *)
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
(* VARIANT CatchEdge: TRUE = the real worklist; FALSE = an Enter's catch    *)
(* edge dropped, so a handler reached only by an exception reads as dead    *)
(* (the reason a try body was never proven dead before the CFG had it).   *)
(*                                                                          *)
(* formal(dev/formal/ProvenDead.tla): a statement stmt_is_proven_unreachable *)
(* proves dead has no control-flow path from entry.                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS N, CondFallthrough, CatchEdge

ASSUME N \in Nat /\ N >= 1
ASSUME CondFallthrough \in BOOLEAN
ASSUME CatchEdge \in BOOLEAN

Idx == 1..N
Stmts == {[k |-> "plain"], [k |-> "return"], [k |-> "leave"]} \cup
         {[k |-> "goto", t |-> t] : t \in Idx} \cup {[k |-> "gotoifnot", t |-> t] : t \in Idx} \cup
         {[k |-> "enter", t |-> t] : t \in Idx}
Programs == [Idx -> Stmts]

VARIABLE prog
vars == <<prog>>

IsJump(s) == s.k \in {"goto", "gotoifnot", "enter"}   \* an Enter's catch destination is a jump target
IsTerm(s) == s.k \in {"goto", "gotoifnot", "return", "enter", "leave"}

\* ground truth: statement-level successors
Succ(p, i) == CASE p[i].k = "goto"      -> {p[i].t}
                [] p[i].k = "gotoifnot" -> {p[i].t} \cup (IF i < N THEN {i + 1} ELSE {})
                [] p[i].k = "enter"     -> {p[i].t} \cup (IF i < N THEN {i + 1} ELSE {})
                [] p[i].k = "return"    -> {}
                [] OTHER                -> IF i < N THEN {i + 1} ELSE {}
RECURSIVE ReachFrom(_, _)
ReachFrom(p, S) == LET nxt == S \cup UNION {Succ(p, i) : i \in S} IN IF nxt = S THEN S ELSE ReachFrom(p, nxt)
Reachable(p) == ReachFrom(p, {1})

\* nir_cfg: a block starts at 1, after a terminator (an Enter and a :leave included), at an Enter,
\* at every jump target and catch destination; the block containing statement i is the last
\* start at or before it (block ids = start indices)
Targets(p) == {p[i].t : i \in {j \in Idx : IsJump(p[j])}}
Starts(p) == {i \in Idx : i = 1 \/ IsTerm(p[i - 1]) \/ i \in Targets(p) \/ p[i].k = "enter"}
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
         [] term.k = "enter" -> (IF CatchEdge THEN {blk[term.t]} ELSE {}) \cup next
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
