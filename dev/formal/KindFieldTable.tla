---------------------------- MODULE KindFieldTable ----------------------------
(***************************************************************************)
(* formal(dev/formal/KindFieldTable.tla): a DataType's own field read at    *)
(* run time (src/code_generator.jl visitInstanceGet, a field of a kind      *)
(* named at run time), answered from a table per field indexed by the type  *)
(* value's class id (src/julia/classes.jl kind_field_table).                 *)
(*                                                                           *)
(* Julia's DataType is jl_datatype_t (julia/src/julia.h:605-626): name,      *)
(* super, parameters, types, instance, layout, hash, flags. getfield by a    *)
(* name only run time knows is jl_f_getfield (julia/src/builtins.c:1023):   *)
(* the field's value, UndefRefError where it is #undef (a non-singleton's   *)
(* `instance`). WasmTarget's type value holds dart's _InterfaceType layout  *)
(* (isDeclaredNullable, classId, typeArguments = Julia's `parameters`); the *)
(* other fields as fields would be constant cycles (julia/src/jltypes.c:2966 *)
(* `jl_any_type->super = jl_any_type`), which constants refuse (Constants.tla*)
(* CyclesReject). So each is a table by class id, as dart keeps its per-    *)
(* class runtime facts (pkg/dart2wasm/lib/types.dart:1424 _getTypeNames, a   *)
(* table by class id): an entry's VALUE, and beside it its STATE, set (the   *)
(* value is Julia's), undef (Julia's #undef, UndefRefError) or gap (a value  *)
(* no constant of the closed world can hold, the fatal arm, located).        *)
(*                                                                           *)
(* ABSTRACTION. Classes: Any, Num (abstract below Any), Int (concrete below  *)
(* Num), Nothing (a singleton, its instance `nothing`, which WasmTarget      *)
(* holds as the null reference), Fn (a singleton whose instance is a value   *)
(* of a class no constant holds). Fields: super, instance, hash. The read's  *)
(* receiver is any class's type value; the claims hold of every one.         *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   ReadAgrees    a read answers Julia's value, Julia's UndefRefError, or   *)
(*                 the fatal gap: never another value, never a value where   *)
(*                 Julia raises                                              *)
(*   ReadAnswers   where the entry's value can be held, the read answers     *)
(*                 Julia's (value or UndefRefError)                          *)
(*   SuperClosed   every class's super is a class with its own entries       *)
(* Broken variants, each refuted by ReadAgrees: NullIsUndef (no state, a     *)
(* null entry read as #undef: Nothing's instance raises), GapIsNull (no      *)
(* state, a gap stored as null and read as `nothing`).                       *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    NullIsUndef,   \* Broken: the table keeps no state; a null value reads as #undef
    GapIsNull      \* Broken: the table keeps no state; a gap is stored as null, read as the value null

Classes == {"Any", "Num", "Int", "Nothing", "Fn"}
Fields  == {"super", "instance", "hash"}
Undef   == "undef"           \* Julia's #undef
Null    == "null"            \* the null reference: WasmTarget's `nothing`
Unheld  == "unheld"          \* a value no constant of the closed world holds
UndefRefError == "UndefRefError"
Fatal   == "fatal"

Super == [c \in Classes |-> CASE c = "Int" -> "Num" [] OTHER -> "Any"]
\* Julia's value of each field of each class's type value
Julia(c, f) ==
    CASE f = "super" -> Super[c]
      [] f = "hash" -> CASE c = "Any" -> "h1" [] c = "Num" -> "h2" [] c = "Int" -> "h3" [] c = "Nothing" -> "h4" [] OTHER -> "h5"
      [] f = "instance" -> CASE c = "Nothing" -> Null [] c = "Fn" -> Unheld [] OTHER -> Undef

\* the table as it is built: each entry's value and its state
State(c, f) == IF Julia(c, f) = Undef THEN "undef" ELSE IF Julia(c, f) = Unheld THEN "gap" ELSE "set"
Value(c, f) == IF State(c, f) = "set" THEN Julia(c, f) ELSE Null
\* the read: the class id's entry; the state decides, unless a Broken variant drops it
Read(c, f) ==
    IF NullIsUndef \/ GapIsNull
    THEN IF Value(c, f) = Null
         THEN (IF NullIsUndef THEN UndefRefError ELSE Null)
         ELSE Value(c, f)
    ELSE CASE State(c, f) = "set" -> Value(c, f)
           [] State(c, f) = "undef" -> UndefRefError
           [] OTHER -> Fatal

\* Julia's answer: the value, or UndefRefError for #undef
Answer(c, f) == IF Julia(c, f) = Undef THEN UndefRefError ELSE Julia(c, f)

VARIABLE recv
Init == recv \in Classes
Next == UNCHANGED recv
Spec == Init /\ [][Next]_recv

TypeOK      == recv \in Classes
ReadAgrees  == \A f \in Fields : Read(recv, f) \in {Answer(recv, f), Fatal}
ReadAnswers == \A f \in Fields : Julia(recv, f) # Unheld => Read(recv, f) = Answer(recv, f)
SuperClosed == \A c \in Classes : Super[c] \in Classes
=============================================================================
