------------------------------ MODULE DefiniteInit ------------------------------
(***************************************************************************)
(* A TLA+ model of `_definitely_initializes_in_nir` (src/codegen/            *)
(* statements.jl): the proof that a partially-initialized `%new` object --   *)
(* some fields left undefined, to be stored later -- has every missing field *)
(* stored before anything reads the object, on every path. When it answers *)
(* true, the lowering allocates the object once and fills the fields in     *)
(* place; a wrong true lets code read a field that was never stored.        *)
(* parity(quarantine: a partial `%new` leaves fields undefined until later  *)
(* stores; Dart's definite assignment is a front-end guarantee, so dart2wasm *)
(* never proves it).                                                        *)
(*                                                                          *)
(* WHAT THE REAL FUNCTION DOES (read from source). A worklist from          *)
(* start_pc with `incoming[start_pc] = {}`: at each statement, a            *)
(* `setfield!(subject, f, _)` of a missing field adds f; any other use of   *)
(* the subject while a missing field is unassigned answers false. The      *)
(* successors are a goto's target, a goto-if-not's fall-through and target, *)
(* nothing after a return, else the next statement. A successor before      *)
(* start_pc (a back edge out of the region) answers false. Each successor's *)
(* state is the INTERSECTION of the states arriving on its edges; a         *)
(* successor is re-queued whenever that state changes.                      *)
(*                                                                          *)
(* THE CLAIM (Sound): an answer of true means no execution path from        *)
(* start_pc reads the subject before every missing field is stored.         *)
(*                                                                          *)
(* WHAT IS ABSTRACTED. Two missing fields; statements write field 1 or 2,   *)
(* use the subject, goto, goto-if-not, return, or do something else. The   *)
(* ground truth is reachability over (statement, fields stored so far)     *)
(* pairs -- every path, loops included. Init chooses every program of N    *)
(* statements; start_pc = 1.                                               *)
(*                                                                          *)
(* VARIANT Meet: "Intersect" = the real code; "Union" = a state merged by   *)
(* union, the may-analysis in place of the must-analysis.                   *)
(*                                                                          *)
(* formal(dev/formal/DefiniteInit.tla): an answer of true means every path  *)
(* stores each missing field before the object is read.                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS N, Meet

ASSUME N \in Nat /\ N >= 1
ASSUME Meet \in {"Intersect", "Union"}

Idx == 1..N
Missing == {1, 2}
Stmts == {[k |-> "write", f |-> 1], [k |-> "write", f |-> 2], [k |-> "use"],
          [k |-> "plain"], [k |-> "return"]} \cup
         {[k |-> "goto", t |-> t] : t \in Idx} \cup {[k |-> "gotoifnot", t |-> t] : t \in Idx}
Programs == [Idx -> Stmts]

VARIABLE prog
vars == <<prog>>

Succ(p, i) == CASE p[i].k = "goto"      -> {p[i].t}
                [] p[i].k = "gotoifnot" -> {p[i].t} \cup (IF i < N THEN {i + 1} ELSE {})
                [] p[i].k = "return"    -> {}
                [] OTHER                -> IF i < N THEN {i + 1} ELSE {}

After(p, i, A) == IF p[i].k = "write" THEN A \cup {p[i].f} ELSE A

\* ground truth: every (statement, stored-fields) pair some path reaches
RECURSIVE Paths(_, _)
Paths(p, S) ==
    LET nxt == S \cup UNION {{<<d, After(p, pr[1], pr[2])>> : d \in Succ(p, pr[1])} : pr \in S}
    IN IF nxt = S THEN S ELSE Paths(p, nxt)

ReadsEarly(p) == \E pr \in Paths(p, {<<1, {}>>}) : p[pr[1]].k = "use" /\ ~(Missing \subseteq pr[2])

\* the worklist's fixpoint: incoming[pc] (absent = not reached), as the real code computes it
Merge(a, b) == IF Meet = "Intersect" THEN a \cap b ELSE a \cup b

RECURSIVE Solve(_, _, _)
\* inc: the incoming-state function over the reached statements; q: the queue as a set
Solve(p, inc, q) ==
    IF q = {} THEN [ok |-> TRUE, inc |-> inc]
    ELSE LET pc == CHOOSE x \in q : \A y \in q : x <= y
             A  == inc[pc]
             useFail == p[pc].k = "use" /\ ~(Missing \subseteq A)
             out == After(p, pc, A)
             succ == Succ(p, pc)
             new(d) == IF d \in DOMAIN inc THEN Merge(inc[d], out) ELSE out
             changed == {d \in succ : d \notin DOMAIN inc \/ new(d) # inc[d]}
             inc2 == [d \in DOMAIN inc \cup succ |-> IF d \in succ THEN new(d) ELSE inc[d]]
         IN IF useFail THEN [ok |-> FALSE, inc |-> inc]
            ELSE Solve(p, inc2, (q \ {pc}) \cup changed)

Answer(p) == Solve(p, [x \in {1} |-> {}], {1}).ok

Init == prog \in Programs
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == prog \in Programs

Sound == Answer(prog) => ~ReadsEarly(prog)
=============================================================================
