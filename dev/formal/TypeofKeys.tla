------------------------------ MODULE TypeofKeys ------------------------------
(***************************************************************************)
(* A TLA+ model of the keys WasmTarget's apply_type cache takes for an     *)
(* operand that is Julia's typeof of a value v (src/julia/classes.jl       *)
(* typeof_keys, read by src/intrinsics.jl's run_time_type arm), against    *)
(* the types typeof answers at run time.                                   *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. Julia infers `typeof(v)` as Type{<:T}, T v's   *)
(* inferred type: a type of more than one value, which the cache cannot    *)
(* key. Its values are the types of v's values. Julia's typeof of a tuple  *)
(* is the tuple type of its elements' types (julia/src/builtins.c jl_f_    *)
(* tuple, julia/src/jltypes.c:2477 jl_inst_arg_tuple_type), so for T a     *)
(* tuple type the keys are the split of its parameters' unions (Core.      *)
(* Compiler's switchtupleunion, Compiler/src/typeutils.jl:261), for any    *)
(* other T its union's members; the keys are taken only where every split *)
(* is a concrete type, whose every value's type is the split itself (a     *)
(* concrete type has no subtype). Where one is not (an element typed       *)
(* Type{X}, whose value's type is DataType; an abstract element) the       *)
(* operand keeps its inferred type, which the cache refuses, located.      *)
(*                                                                         *)
(* THE MODEL. Each position of the tuple holds a set of declared members   *)
(* (its union's), each member a set of run-time types of its values: a     *)
(* concrete member's is itself alone. A value's type is one run-time type  *)
(* per position. The keys are the product of the members where every      *)
(* member is concrete, else none (the cache refuses: Refused).             *)
(*                                                                         *)
(* THE CLAIMS. Covered: unless refused, every type a value can have is a   *)
(* key, so the cache's lookup over the keys (TypeCacheLookup.tla) never    *)
(* misses. Exact: unless refused, every key is the type of some value.     *)
(*                                                                         *)
(* BROKEN. Declared: the key is the declared tuple type itself (the        *)
(* operand's Type{<:T} read as Type{T}), which no value has (breaks        *)
(* Covered). NoConcreteCheck: the product is taken over members that are   *)
(* not concrete, keying Type{X} where the value's type is DataType (breaks *)
(* Covered).                                                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Decl,             \* [1..N -> SUBSET Members]: each position's union members
    RunTypes,         \* [Members -> SUBSET Types]: the run-time types of a member's values
    Declared,         \* BOOLEAN: key by the declared tuple type
    NoConcreteCheck   \* BOOLEAN: take the product without the concreteness check

VARIABLE keys

Pos == DOMAIN Decl
Members == DOMAIN RunTypes
\* a concrete member: its values' run-time type is itself alone
Concrete(m) == RunTypes[m] = {m}
\* every type a value of v can have at run time: one run-time type per position
ValueTypes == {t \in [Pos -> UNION {RunTypes[m] : m \in Members}] :
                 \A p \in Pos : \E m \in Decl[p] : t[p] \in RunTypes[m]}
\* the split of the parameters' unions (switchtupleunion): one member per position
Splits == {k \in [Pos -> Members] : \A p \in Pos : k[p] \in Decl[p]}
AllConcrete == \A p \in Pos : \A m \in Decl[p] : Concrete(m)
\* the declared tuple type, no value's type: a marker no split equals
DeclaredKey == [p \in Pos |-> "declared"]
Made == IF Declared THEN {DeclaredKey}
        ELSE IF AllConcrete \/ NoConcreteCheck THEN Splits
        ELSE {}
Refused == keys = {}

TypeOK == keys = Made
Init == keys = Made
Next == UNCHANGED keys
Spec == Init /\ [][Next]_keys

Covered == Refused \/ ValueTypes \subseteq keys
Exact == Refused \/ keys \subseteq ValueTypes
=============================================================================
