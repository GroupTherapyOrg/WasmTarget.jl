------------------------- MODULE ObjectIdDispatch --------------------------
(***************************************************************************)
(* A TLA+ model of objectid of a value whose class only run time knows, as  *)
(* WasmTarget dispatches it: one selector of dart's dispatch table          *)
(* (dispatch_table.dart:501 DispatchTable.build, :689-701: a selector of    *)
(* more than one range and no static-dispatch pragma is called through its  *)
(* row, translator.dart:911 callDispatchTable), as dart reaches             *)
(* Object.hashCode (object_patch.dart:31). Julia's own answer is one C      *)
(* function, jl_object_id_ (julia/src/builtins.c:489, :459), which switches *)
(* on the value's type tag; the row is that switch, one target a class.     *)
(*                                                                           *)
(* The receiver. Julia dispatches on every argument; objectid has one, x,   *)
(* after its function object, a singleton that holds no state. The row's   *)
(* receiver is x, the first argument after the function object. A function *)
(* object that holds state (a closure's captures) would be a second value  *)
(* the target reads, which one row indexed by one class id cannot pick by,  *)
(* so a selector over such a function stays refused, located.               *)
(*                                                                           *)
(* The targets of a class c, by its kind (jl_object_id_'s arms): an        *)
(* identity (a mutable answered by its identity) the one shared identity    *)
(* target; a Symbol its hash's; a String its bytes' memhash; an immutable  *)
(* class its own specialization jl_object_id(::C), which only a second     *)
(* inference round makes; a class whose target meets a construct WasmTarget *)
(* does not port at codegen (a gap) the fatal form: the located text to the *)
(* host, then the trap, which no catch of the program observes.             *)
(*                                                                           *)
(* ABSTRACTION. Classes are the class ids 0..N-1, each of one kind. Round 1 *)
(* infers the program; its objectid sites are Sites1, each with the        *)
(* concrete classes its operand admits. Round 2 queues jl_object_id(::C)   *)
(* for each immutable or gap class those sites admit and infers once more;  *)
(* the bodies it adds hold the sites Sites2 (an immutable's field loop      *)
(* reaching Any), active only when round 2 queued a class. After round 2    *)
(* every active site's classes are checked against the targets: a class    *)
(* that would need a target round 2 did not make is a located compile-time  *)
(* refusal, never a third round. The row is then built, each class its      *)
(* target, and checked again: a site's class with no target is refused,     *)
(* never an unfilled slot (dart's unreachable) or a default target. Packing *)
(* the row beside other selectors' is FieldSelectorTable.tla's.             *)
(*                                                                           *)
(* Claims (at the end, where the compile was not refused):                  *)
(*   OneTarget         every class of every active site has a target in    *)
(*                     the row                                              *)
(*   AgreesWithStatic  a class's target is the arm jl_object_id takes at   *)
(*                     its static type                                      *)
(*   GapFatal          a gap class's target is the fatal form              *)
(*   TwoRounds         inference runs at most two rounds (every state)     *)
(* Broken variants: MissingArm (one site class's target left out and the   *)
(* coverage check skipped: OneTarget), GapCatchable (a gap's target raises *)
(* an exception a catch sees: GapFatal), ThirdRound (a class round 2 meets  *)
(* queues another round: TwoRounds).                                        *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    N,             \* classes are the class ids 0..N-1
    Sites1,        \* round 1's objectid sites
    Sites2,        \* the sites of the bodies round 2 adds
    MissingArm,    \* Broken: a site class's target left out, the coverage check skipped
    GapCatchable,  \* Broken: a gap class's target raises a catchable exception
    ThirdRound     \* Broken: a class round 2 meets queues a third round

Classes == 0..(N - 1)
Kinds == {"identity", "symbol", "string", "immut", "gap"}
Sites == Sites1 \cup Sites2

\* a target: its arm and, for a per-class one, its class; None is the unfilled slot
IdT == <<"identity", -1>>
SymT == <<"symbol", -1>>
StrT == <<"string", -1>>
ImmT(c) == <<"immut", c>>
FatalT(c) == <<"fatal", c>>
ThrowT(c) == <<"throw", c>>
None == <<"none", -1>>
TargetSet == {IdT, SymT, StrT, None} \cup {ImmT(c) : c \in Classes} \cup {FatalT(c) : c \in Classes} \cup {ThrowT(c) : c \in Classes}

VARIABLES kind, recv, round, queued, active, row, phase
vars == <<kind, recv, round, queued, active, row, phase>>

\* a class whose target is its own specialization, made only by round 2
PerClass(c) == kind[c] \in {"immut", "gap"}
SiteClasses(S) == UNION {recv[s] : s \in S}
\* the arm jl_object_id takes at the class's static type
Static(c) == CASE kind[c] = "identity" -> IdT
              [] kind[c] = "symbol"   -> SymT
              [] kind[c] = "string"   -> StrT
              [] kind[c] = "immut"    -> ImmT(c)
              [] kind[c] = "gap"      -> FatalT(c)
\* the target build gives a class: a per-class one only when queued
Built(c) == IF PerClass(c) /\ c \notin queued THEN None
            ELSE IF kind[c] = "gap" /\ GapCatchable THEN ThrowT(c)
            ELSE Static(c)
\* the classes the active sites admit that would need a target round 2 did not make
Unmade == {c \in SiteClasses(active) : PerClass(c) /\ c \notin queued}

TypeOK ==
    /\ kind \in [Classes -> Kinds]
    /\ recv \in [Sites -> (SUBSET Classes) \ {{}}]
    /\ round \in Nat
    /\ queued \subseteq Classes
    /\ active \subseteq Sites
    /\ row \in [Classes -> TargetSet]
    /\ phase \in {"infer", "check", "build", "done", "refused"}

Init ==
    /\ kind \in [Classes -> Kinds]
    /\ recv \in [Sites -> (SUBSET Classes) \ {{}}]
    /\ round = 0
    /\ queued = {}
    /\ active = {}
    /\ row = [c \in Classes |-> None]
    /\ phase = "infer"

\* round 1: the program inferred, its sites read
Round1 ==
    /\ phase = "infer" /\ round = 0
    /\ round' = 1
    /\ active' = Sites1
    /\ UNCHANGED <<kind, recv, queued, row, phase>>

\* a further round: jl_object_id(::C) queued for each per-class class the sites admit, inferred once more; its
\* bodies' sites join (Sites2, once any class is queued)
NextRound ==
    /\ phase = "infer" /\ round >= 1
    /\ \/ round = 1
       \/ ThirdRound /\ Unmade # {}
    /\ queued' = queued \cup {c \in SiteClasses(active) : PerClass(c)}
    /\ active' = IF queued' # {} THEN active \cup Sites2 ELSE active
    /\ round' = round + 1
    /\ UNCHANGED <<kind, recv, row, phase>>

\* after round 2: a class needing a target no round made is refused, located, never a third round
Check ==
    /\ phase = "infer" /\ round >= 2
    /\ ~(ThirdRound /\ Unmade # {})
    /\ phase' = IF Unmade = {} THEN "build" ELSE "refused"
    /\ UNCHANGED <<kind, recv, round, queued, active, row>>

\* the row: each class its target; MissingArm leaves one site class's target out
Build ==
    /\ phase = "build"
    /\ \E drop \in (IF MissingArm THEN SiteClasses(active) ELSE {-1}) :
         row' = [c \in Classes |-> IF c = drop THEN None ELSE Built(c)]
    /\ phase' = "check"
    /\ UNCHANGED <<kind, recv, round, queued, active>>

\* the row checked against every active site's classes: a class with no target refused, located (the plant: a
\* selector with one class's target removed is refused by its words); MissingArm skips it
Cover ==
    /\ phase = "check"
    /\ phase' = IF ~MissingArm /\ \E c \in SiteClasses(active) : row[c] = None THEN "refused" ELSE "done"
    /\ UNCHANGED <<kind, recv, round, queued, active, row>>

\* the run ends: its terminal states stutter explicitly
Done == phase \in {"done", "refused"} /\ UNCHANGED vars

Next == Round1 \/ NextRound \/ Check \/ Build \/ Cover \/ Done
Spec == Init /\ [][Next]_vars /\ WF_vars(Round1 \/ NextRound \/ Check \/ Build \/ Cover)

OneTarget == phase = "done" =>
    \A c \in SiteClasses(active) : row[c] # None

AgreesWithStatic == phase = "done" =>
    \A c \in SiteClasses(active) : kind[c] # "gap" => row[c] = Static(c)

GapFatal == phase = "done" =>
    \A c \in SiteClasses(active) : kind[c] = "gap" => row[c] = FatalT(c)

TwoRounds == round <= 2

Ends == <>(phase \in {"done", "refused"})
=============================================================================
