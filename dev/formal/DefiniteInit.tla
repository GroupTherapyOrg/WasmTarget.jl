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
(* start_pc, the statement after the `%new`, with `incoming[start_pc] = {}`: *)
(* at each statement, a `setfield!(subject, f, _)` of a missing field adds  *)
(* f; any other use of the subject while a missing field is unassigned     *)
(* answers false -- an UpsilonNode carrying the subject to a handler is     *)
(* such a use (nir_uses). The successors are the one CFG's (nir_cfg,        *)
(* Julia's compute_basic_blocks): a goto's target, a goto-if-not's          *)
(* fall-through and target, an Enter's next statement and its catch         *)
(* destination (the catch edge, at the Enter only), nothing after a return, *)
(* none for a statement in no block (a trailing `nothing` after the body's  *)
(* last terminator, Julia's ir.jl:84-89, block_of 0), else the next         *)
(* statement. A successor before start_pc (a back edge out of the region)  *)
(* answers false. Each successor's state is the INTERSECTION of the states  *)
(* arriving on its edges; a successor is re-queued whenever that state      *)
(* changes.                                                                 *)
(*                                                                          *)
(* THE GROUND TRUTH. Every path from start_pc over (statement, fields        *)
(* stored, whether the subject's SSA value is defined there, the fields     *)
(* stored when an upsilon last carried it): a statement inside a try        *)
(* region -- after its Enter, before its catch destination -- may throw and *)
(* reach the handler, not the Enter alone. A `%new` inside a try body does  *)
(* not dominate its handler, so the handler cannot name the subject: it     *)
(* reaches it only through a PhiC reading what an UpsilonNode in the try    *)
(* body carried (the upsilon rule). That is why the proof needs no catch    *)
(* edge from inside the region: the upsilon is a use, checked where it      *)
(* runs, and the handler reads only what it carried. A `%new` before the    *)
(* Enter dominates the handler, and the Enter's catch edge carries its      *)
(* fewest stored fields, every path into the region passing the Enter      *)
(* (Julia enters a try body only through its Enter).                        *)
(*                                                                          *)
(* THE CLAIM (Sound): an answer of true means no execution path from        *)
(* start_pc reads the subject before every missing field is stored.         *)
(*                                                                          *)
(* WHAT IS ABSTRACTED. Two missing fields; statements write field 1 or 2,   *)
(* use the subject, carry it to a handler (upsilon), read a handler's slot  *)
(* (phic), goto, goto-if-not, enter, return, are a `nothing`, or do         *)
(* something else. Init chooses every well-formed program of N statements   *)
(* (Julia's invariants: a body with trailing `nothing`s ends in a           *)
(* terminator no jump passes, no jump targets them, and a try body is       *)
(* entered only through its Enter, whose catch destination follows it);     *)
(* Ext = FALSE keeps the classic kinds and start_pc = 1, Ext = TRUE adds    *)
(* `nothing`, the upsilon and the PhiC and lets start_pc be any statement,  *)
(* a try body's included.                                                   *)
(*                                                                          *)
(* VARIANT Meet: "Intersect" = the real code; "Union" = a state merged by   *)
(* union, the may-analysis in place of the must-analysis.                   *)
(* VARIANT CatchEdge: TRUE = the real code; FALSE = an Enter's catch edge   *)
(* not followed, so a handler that reads the object before a field is      *)
(* stored goes unseen and the proof answers true where a path reads it.    *)
(* VARIANT UpsilonIsUse: TRUE = the real code; FALSE = an upsilon not read  *)
(* as a use, so a handler reads an object its try body carried half built. *)
(* VARIANT TrailingOnly: TRUE = the real code (only a trailing `nothing` is *)
(* in no block); FALSE = every `nothing` in no block, so a path through one *)
(* mid-body stops there and a later read goes unseen.                       *)
(*                                                                          *)
(* formal(dev/formal/DefiniteInit.tla): an answer of true means every path  *)
(* stores each missing field before the object is read.                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS N, Meet, CatchEdge, UpsilonIsUse, TrailingOnly, Ext

ASSUME N \in Nat /\ N >= 1
ASSUME Meet \in {"Intersect", "Union"}
ASSUME CatchEdge \in BOOLEAN /\ UpsilonIsUse \in BOOLEAN /\ TrailingOnly \in BOOLEAN /\ Ext \in BOOLEAN

Idx == 1..N
Missing == {1, 2}
Classic == {[k |-> "write", f |-> 1], [k |-> "write", f |-> 2], [k |-> "use"],
            [k |-> "plain"], [k |-> "return"]} \cup
           {[k |-> "goto", t |-> t] : t \in Idx} \cup {[k |-> "gotoifnot", t |-> t] : t \in Idx} \cup
           {[k |-> "enter", t |-> t] : t \in Idx}
Stmts == IF Ext THEN Classic \cup {[k |-> "nothing"], [k |-> "upsilon"], [k |-> "phic"]} ELSE Classic
Programs == [Idx -> Stmts]
Starts == IF Ext THEN Idx ELSE {1}

VARIABLES prog, start
vars == <<prog, start>>

MaxOf(S) == CHOOSE m \in S : \A x \in S : x <= m
IsJump(s) == s.k \in {"goto", "gotoifnot", "enter"}
\* the statements a try body holds: after its Enter, before its catch destination
Region(p, e) == IF p[e].k = "enter" THEN {i \in Idx : e < i /\ i < p[e].t} ELSE {}
\* a statement in no block: a trailing `nothing` (TrailingOnly), or any `nothing` (the Broken rule)
Real(p) == {i \in Idx : p[i].k # "nothing"}
NoBlock(p, i) == IF TrailingOnly THEN \A j \in i..N : p[j].k = "nothing" ELSE p[i].k = "nothing"

WellFormed(p) ==
    \* a body with trailing `nothing`s ends in a terminator no path falls out of, and no jump targets them
    /\ (p[N].k = "nothing" =>
          Real(p) # {} /\ p[MaxOf(Real(p))].k \in {"return", "goto"} /\
          \A i \in Idx : IsJump(p[i]) => p[i].t <= MaxOf(Real(p)))
    \* an Enter's catch destination follows it, and a try body is entered only through its Enter (no
    \* jump or other Enter's catch destination lands inside it from outside: a nested region's lies
    \* inside the outer one)
    /\ \A e \in Idx : p[e].k = "enter" =>
          /\ p[e].t > e
          /\ \A i \in Idx : (IsJump(p[i]) /\ p[i].t \in Region(p, e)) => i \in Region(p, e)

\* ground truth: the normal successors, and a throw from a try body (or its Enter) to its handler
Next1(p, i) == IF i < N THEN {i + 1} ELSE {}
Succ(p, i) == CASE p[i].k = "goto"      -> {p[i].t}
                [] p[i].k = "gotoifnot" -> {p[i].t} \cup Next1(p, i)
                [] p[i].k = "enter"     -> {p[i].t} \cup Next1(p, i)
                [] p[i].k = "return"    -> {}
                [] OTHER                -> Next1(p, i)
Catches(p, i) == {e \in Idx : p[e].k = "enter" /\ i \in Region(p, e)}

After(p, i, A) == IF p[i].k = "write" THEN A \cup {p[i].f} ELSE A

\* a ground-truth state <<pc, stored, defined, carried, carried fields>>: `defined` whether the
\* subject's SSA value is defined there (re-made at start_pc, undefined before it and in a handler of
\* a try body that made it), `carried` whether an upsilon carried it, with the fields stored then
Arrive(p, s, d, A, av, c, sn) ==
    IF d = s THEN <<d, {}, TRUE, c, sn>> ELSE IF d < s THEN <<d, A, FALSE, c, sn>> ELSE <<d, A, av, c, sn>>
Step(p, s, st) ==
    LET i == st[1]  A == st[2]  av == st[3]  c == st[4]  sn == st[5]
        ups == p[i].k = "upsilon" /\ av
        normal == {Arrive(p, s, d, After(p, i, A), av, c \/ ups, IF ups THEN A ELSE sn) : d \in Succ(p, i)}
        \* a throw before the statement's own effect; a try body that made the subject leaves it
        \* undefined in the handler
        thrown == {<<p[e].t, A, av /\ ~(s \in Region(p, e)), c, sn>> : e \in Catches(p, i) \cup (IF p[i].k = "enter" THEN {i} ELSE {})}
    IN normal \cup thrown
RECURSIVE Paths(_, _, _)
Paths(p, s, S) ==
    LET nxt == S \cup UNION {Step(p, s, st) : st \in S}
    IN IF nxt = S THEN S ELSE Paths(p, s, nxt)

ReadsEarly(p, s) == \E st \in Paths(p, s, {<<s, {}, TRUE, FALSE, {}>>}) :
    \/ p[st[1]].k = "use" /\ st[3] /\ ~(Missing \subseteq st[2])
    \/ p[st[1]].k = "phic" /\ st[4] /\ ~(Missing \subseteq st[5])

\* the proof's successors: the one CFG's (the catch edge at the Enter only), none for a statement in
\* no block, or without the catch edge (the Broken variant)
AlgoSucc(p, i) == IF NoBlock(p, i) THEN {}
                  ELSE IF p[i].k = "enter" /\ ~CatchEdge THEN Next1(p, i) ELSE Succ(p, i)
\* the statements the proof reads as a use of the subject (nir_uses): a use, and an upsilon
Uses(p, i) == p[i].k = "use" \/ (p[i].k = "upsilon" /\ UpsilonIsUse)

\* the worklist's fixpoint: incoming[pc] (absent = not reached), as the real code computes it
Merge(a, b) == IF Meet = "Intersect" THEN a \cap b ELSE a \cup b

RECURSIVE Solve(_, _, _, _)
\* inc: the incoming-state function over the reached statements; q: the queue as a set
Solve(p, s, inc, q) ==
    IF q = {} THEN [ok |-> TRUE, inc |-> inc]
    ELSE LET pc == CHOOSE x \in q : \A y \in q : x <= y
             A  == inc[pc]
             useFail == Uses(p, pc) /\ ~(Missing \subseteq A)
             out == After(p, pc, A)
             succ == AlgoSucc(p, pc)
             new(d) == IF d \in DOMAIN inc THEN Merge(inc[d], out) ELSE out
             changed == {d \in succ : d \notin DOMAIN inc \/ new(d) # inc[d]}
             inc2 == [d \in DOMAIN inc \cup succ |-> IF d \in succ THEN new(d) ELSE inc[d]]
         IN IF useFail \/ (\E d \in succ : d < s) THEN [ok |-> FALSE, inc |-> inc]
            ELSE Solve(p, s, inc2, (q \ {pc}) \cup changed)

Answer(p, s) == Solve(p, s, [x \in {s} |-> {}], {s}).ok

Init == prog \in Programs /\ start \in Starts /\ WellFormed(prog)
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == prog \in Programs /\ start \in Starts

Sound == Answer(prog, start) => ~ReadsEarly(prog, start)
=============================================================================
