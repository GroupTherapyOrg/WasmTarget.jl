---------------------------- MODULE ClassIdSwitch ----------------------------
(***************************************************************************)
(* A TLA+ model of the inline classId switch: the dispatch an erased call  *)
(* compiles to when its callee has several specializations that differ in *)
(* one argument (`_try_inline_typeid_dispatch`, src/codegen/calls.jl), and *)
(* the row test every closure vtable entry makes, one body or several      *)
(* (`_emit_closure_arg_tests!`, src/codegen/closures.jl).                  *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. The collector numbers the classes the program  *)
(* instantiates (`_dynamic_dispatch_candidate_mis`, trimcollect.jl): a     *)
(* `%new` and the builtins that allocate without one (`memoryrefnew` for a *)
(* MemoryRef, `jl_alloc_genericmemory` for a Memory). Each specialization  *)
(* gets a row, tried in program order, whose test is its parameter type:   *)
(* a classed value's header classId against the classes the type admits   *)
(* (one for a concrete type, several for an abstract one); a Memory or a   *)
(* SimpleVector, a bare wasm array with no header, by its array type,      *)
(* which tells it apart only when no other numbered class is that array    *)
(* type (`bare_array_partition`). A call with a candidate whose class      *)
(* shares its array type rejects at compile time. The matching row calls   *)
(* its specialization; no match traps, where Julia throws MethodError.     *)
(*                                                                         *)
(* THE CLAIM. The entry never runs a specialization Julia would not select *)
(* for the value (NoWrongMethod); traps only where Julia has no method for *)
(* the value's class (TrapOnlyWhenNoMethod); and rejects only a call with  *)
(* a candidate class no test tells apart (RejectOnlyWhenShared). Broken    *)
(* variants: a collector that saw only `%new` (a MemoryRef held erased had *)
(* no row); the rule before 2026-09-30, a shared candidate given no row    *)
(* (a call reaching it trapped where Julia answers); and a row that tests  *)
(* only the value's wasm layout (the single-body closure entry cast its    *)
(* argument, and a struct of another class with one deduplicated layout    *)
(* ran this body: native 23, wasm 13, dev/AUDIT.md A4C3).                  *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Classes, layouts, array types and            *)
(* specializations are opaque constants; one dispatch position; the        *)
(* specializations' parameter types admit disjoint classes, so Julia's     *)
(* selection is the one that admits the value (overlapping parameter       *)
(* types, which enrollment makes common since 2026-10-06, and the order    *)
(* rows are tried in are Enrollment.tla's). A parameter type that admits a *)
(* type object or a bare array rejects before any row is built             *)
(* (compile.jl, `_closure_param_untestable`), so it is never a candidate   *)
(* here. The model partitions the array types over every class; the inline *)
(* switch restricts the partition to the value's static type, which only   *)
(* removes rejections the model makes. Each behavior checks one erased     *)
(* value of one class.                                                     *)
(*                                                                         *)
(* formal(src/codegen/calls.jl _try_inline_typeid_dispatch): the erased   *)
(* call runs the specialization Julia selects, traps where Julia has none, *)
(* and rejects a candidate class no test tells apart.                      *)
(*                                                                         *)
(* No dart anchor: parity(quarantine: dart dispatches through the selector *)
(* table on a header every object has; WT keeps a Memory as a bare array   *)
(* and switches inline over one call's specializations).                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Classes,          \* the program's runtime classes
    Bare,             \* SUBSET Classes: bare wasm arrays (a Memory, a SimpleVector)
    Layout,           \* [Classes -> Layouts]: what a cast of the value checks (a
                      \* deduplicated struct layout, a bare class's array type)
    Layouts,
    ByBuiltin,        \* SUBSET Classes: allocated by a builtin, never by a %new
    Methods,          \* the callee's specializations at this call, in program order by MOrd
    MOrd,             \* [Methods -> Nat]
    Param,            \* [Methods -> SUBSET Classes]: the classes each parameter type admits
    ObserveBuiltins,  \* BOOLEAN: the collector counts builtin allocations (FALSE = broken)
    RejectShared,     \* BOOLEAN: a shared candidate class rejects the call (FALSE = the old rule)
    CastOnly          \* BOOLEAN: a row tests only the value's layout (TRUE = broken)

VARIABLES v, outcome, done

vars == <<v, outcome, done>>

Trap == "trap"
Reject == "reject"

\* the classes the collector numbers
Observed == {c \in Classes : c \notin ByBuiltin \/ ObserveBuiltins}

\* a bare class another numbered bare class shares its array type with
Shared(c) == c \in Bare /\ \E d \in (Bare \cap Observed) \ {c} : Layout[d] = Layout[c]

Candidates == UNION {Param[m] : m \in Methods}

\* the class a row can read for an erased value of class c: a header's classId, or a bare
\* array's class when its array type is its own; else no class (the read fails)
ReadClass(c) ==
    IF c \notin Bare THEN (IF c \in Observed THEN c ELSE Trap)
    ELSE IF c \in Observed /\ ~Shared(c) THEN c ELSE Trap

RowMatches(m, c) ==
    IF CastOnly THEN \E d \in Param[m] : Layout[d] = Layout[c]
    ELSE ReadClass(c) # Trap /\ ReadClass(c) \in Param[m]

FirstRow(c) ==
    LET ms == {m \in Methods : RowMatches(m, c)} IN
    IF ms = {} THEN Trap ELSE CHOOSE m \in ms : \A n \in ms : MOrd[m] <= MOrd[n]

Outcome(c) ==
    IF RejectShared /\ \E d \in Candidates : Shared(d) THEN Reject
    ELSE IF ~RejectShared THEN
        \* the old rule: a shared candidate class gets no row
        LET ms == {m \in Methods : \A d \in Param[m] : ~Shared(d)} IN
        LET hit == {m \in ms : RowMatches(m, c)} IN
        IF hit = {} THEN Trap ELSE CHOOSE m \in hit : \A n \in hit : MOrd[m] <= MOrd[n]
    ELSE FirstRow(c)

Init == v \in Classes /\ outcome = Trap /\ done = FALSE
Step == ~done /\ outcome' = Outcome(v) /\ done' = TRUE /\ UNCHANGED v
Spec == Init /\ [][Step]_vars

TypeOK == v \in Classes /\ outcome \in Methods \cup {Trap, Reject} /\ done \in BOOLEAN

\* a run is the specialization Julia selects for the value's class
NoWrongMethod == done \in BOOLEAN /\ (done /\ outcome \in Methods => v \in Param[outcome])

\* a trap only where Julia has no method for the value's class
TrapOnlyWhenNoMethod ==
    done \in BOOLEAN /\ (done /\ outcome = Trap => ~\E m \in Methods : v \in Param[m])

\* a compile-time rejection only for a candidate class no test tells apart
RejectOnlyWhenShared ==
    done \in BOOLEAN /\ (done /\ outcome = Reject => \E d \in Candidates : Shared(d))
=============================================================================
