---------------------------- MODULE ClassIdSwitch ----------------------------
(***************************************************************************)
(* A TLA+ model of the inline classId switch: the dispatch an erased call  *)
(* compiles to when its callee has several specializations that differ in *)
(* one argument (`_try_inline_typeid_dispatch`, src/codegen/calls.jl), and *)
(* the same row test inside a closure's dispatching vtable entry           *)
(* (`_closure_dispatch_trampoline!`, src/codegen/closures.jl).             *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. The collector numbers the classes the program  *)
(* instantiates (`_dynamic_dispatch_candidate_mis`, trimcollect.jl): a     *)
(* `%new` and, since 2026-09-28, the builtins that allocate without one    *)
(* (`memoryrefnew` for a MemoryRef, `jl_alloc_genericmemory` for a         *)
(* Memory). Each observed class the callee has a specialization for gets a *)
(* row. At the call the switch reads the erased value's class              *)
(* (`emit_class_id!`, builtins.jl): a classed value carries it in its      *)
(* header; a Memory or a SimpleVector is a bare wasm array with no header, *)
(* told by its array type, which works only when no other class is that    *)
(* array type (`_bare_array_classes`). A class it cannot tell apart gets   *)
(* no row. The matching row calls its specialization; no match traps.      *)
(*                                                                         *)
(* THE CLAIM. The switch never runs a specialization Julia would not       *)
(* select for the value (NoWrongMethod), and traps only where Julia has no *)
(* method for the value's class, or the class is a bare array sharing its  *)
(* array type (TrapOnlyWhenUnresolvable). Two Broken variants reproduce    *)
(* what the code did: a collector that saw only `%new` (a MemoryRef held   *)
(* erased had no row and trapped where Julia answers), and a class read    *)
(* that maps a bare array to the first class of its array type (a          *)
(* SimpleVector would run the Memory{Any} method).                         *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Classes, array types and specializations are *)
(* opaque constants; one dispatch position (the switch's only form); one   *)
(* specialization per class (the candidates differ in the dispatch        *)
(* argument). Each behavior checks one erased value of one class.          *)
(*                                                                         *)
(* formal(src/codegen/calls.jl _try_inline_typeid_dispatch): the erased   *)
(* call runs the specialization Julia selects, or traps where Julia has    *)
(* none or the class cannot be told apart.                                 *)
(*                                                                         *)
(* No dart anchor: parity(quarantine: dart dispatches through the selector *)
(* table on a header every object has; WT keeps a Memory as a bare array   *)
(* and switches inline over one call's specializations).                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Classes,          \* the program's runtime classes
    Bare,             \* SUBSET Classes: bare wasm arrays (a Memory, a SimpleVector)
    ArrayType,        \* [Bare -> Types]: the wasm array type a bare class is
    Types,            \* wasm array types
    ByBuiltin,        \* SUBSET Classes: allocated by a builtin, never by a %new
    Ord,              \* [Classes -> Nat]: the order the closed world numbers classes in
    Methods,          \* the callee's specializations at this call
    Param,            \* [Methods -> Classes]: the class each specialization's argument names
    ObserveBuiltins,  \* BOOLEAN: the collector counts builtin allocations (FALSE = broken)
    NaiveBareRead     \* BOOLEAN: a bare array reads as the first class of its array type (TRUE = broken)

VARIABLES v, outcome, done

vars == <<v, outcome, done>>

Trap == "trap"

\* the classes the collector numbers
Observed == {c \in Classes : c \notin ByBuiltin \/ ObserveBuiltins}

\* a bare class another observed bare class shares its array type with
Shared(c) == c \in Bare /\ \E d \in (Bare \cap Observed) \ {c} : ArrayType[d] = ArrayType[c]

\* the classes the switch can tell apart, and so give a row
Distinguishable == {c \in Observed : NaiveBareRead \/ ~Shared(c)}
Rows == {m \in Methods : Param[m] \in Distinguishable}

\* the first observed class, in numbering order, among S
First(S) == CHOOSE c \in S : \A d \in S : Ord[c] <= Ord[d]

\* the class the switch reads for an erased value of class c, or Trap (the header read of a
\* bare array fails its cast)
ReadClass(c) ==
    IF c \notin Bare THEN (IF c \in Observed THEN c ELSE Trap)
    ELSE LET same == {d \in Bare \cap Distinguishable : ArrayType[d] = ArrayType[c]}
         IN IF same = {} THEN Trap
            ELSE IF NaiveBareRead THEN First(same)
            ELSE IF c \in same THEN c ELSE Trap

Outcome(c) ==
    LET k == ReadClass(c) IN
    IF k = Trap THEN Trap
    ELSE IF \E m \in Rows : Param[m] = k THEN CHOOSE m \in Rows : Param[m] = k
    ELSE Trap

Init == v \in Classes /\ outcome = Trap /\ done = FALSE
Step == ~done /\ outcome' = Outcome(v) /\ done' = TRUE /\ UNCHANGED v
Spec == Init /\ [][Step]_vars

TypeOK == v \in Classes /\ outcome \in Methods \cup {Trap} /\ done \in BOOLEAN

\* a run is the specialization Julia selects for the value's class
NoWrongMethod == done \in BOOLEAN /\ (done /\ outcome # Trap => Param[outcome] = v)

\* a trap only where Julia has no method, or where the class cannot be told apart
TrapOnlyWhenUnresolvable ==
    done \in BOOLEAN /\
    (done /\ outcome = Trap => (~\E m \in Methods : Param[m] = v) \/ Shared(v))
=============================================================================
