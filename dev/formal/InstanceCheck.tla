---------------------------- MODULE InstanceCheck ----------------------------
(***************************************************************************)
(* A TLA+ model of the run-time instance check, `x isa T` against a type   *)
(* value `T` known only at run time (dart's _isSubtype and the             *)
(* _checkInstance of each type kind, Julia's jl_isa):                       *)
(*   parity(sdk/lib/_internal/wasm/common/type.dart:1484 _isSubtype)       *)
(*   parity(sdk/lib/_internal/wasm/common/type.dart:1005                   *)
(*          _TypeUniverse.isObjectInterfaceSubtype0)                       *)
(* ported onto Julia's types, whose subtyping Julia itself answers          *)
(* (ledger D3).                                                             *)
(*                                                                          *)
(* WHAT dart DOES.  `_isSubtype(o, t)` answers `t.isDeclaredNullable` for   *)
(* null and otherwise `t._checkInstance(o)`, a virtual call on the kind of  *)
(* the type value.  An interface type's check is the class table: the      *)
(* row-displacement table says whether `o`'s class is a subclass of `t`'s  *)
(* class (_checkSubclassRelationship), then the type arguments are         *)
(* compared through the subclass's substitution.                            *)
(*                                                                          *)
(* HOW JULIA DIFFERS, AND WHY THE MODEL HOLDS IT.  A Julia class is a      *)
(* DataType with its parameters bound (`Vector{Int}`, `AbstractVector{Int}`  *)
(* are two classes), so a class's supertype chain already holds its        *)
(* ancestors' parameters and no substitution is left to do                 *)
(* (types.jl _build_type_rules: the identity).  Julia's parameters are      *)
(* invariant, so `S <: T` for a DataType `T` with no free variable is: `T`  *)
(* is `Any`, or some ancestor of `S` has `T`'s name and `T`'s parameters    *)
(* exactly.  Two kinds of DataType escape the class table, and the check   *)
(* takes each by its own arm, as dart dispatches on the type's kind:        *)
(*   - a Tuple type is covariant (`Tuple{Int,Int} <: Tuple{Real,Real}`,     *)
(*     though `Tuple{Int,Int}`'s supertype is `Any`): its arm checks each   *)
(*     element type of the value's class against the tested one;           *)
(*   - `Type{X}` holds one value, the type `X` (a kind's instances split): *)
(*     its arm is `o === X`.                                                *)
(* A concrete `T` is a class-id equality (jl_isa's `jl_typeis` fast path). *)
(* A `T` with no class in the closed world (no class of the world has it   *)
(* on its chain) admits no value of the world: its check answers false.    *)
(* `T`'s free variables (UnionAll, TypeVar, Vararg) are jl_subtype's        *)
(* existential matching, which the code generator rejects where the tested *)
(* value's inferred type admits one; the model holds none.                 *)
(*                                                                          *)
(* The lattice: Real > {Int, Flt}; AVec{p} > Vec{p}; Tup{p,q}; Type{p};     *)
(* DT, the class of a type value (Julia's DataType); every parameter one of *)
(* Int, Flt, Real, Any.  The closed world is any one to three concrete    *)
(* classes;                                                                 *)
(* the value is an instance of one of them or a type value; the tested     *)
(* type is any DataType of the lattice, numbered in the world or not.      *)
(*                                                                          *)
(* The Tuple arm checks an element type through the class table too, so a   *)
(* Tuple class's element types must be numbered: the class walk numbers    *)
(* every class a numbered class's fields name (a Tuple's fields are its    *)
(* elements), which the model holds (`FieldTypes`).                         *)
(*                                                                          *)
(* Broken variants: `NoTupleArm` checks a Tuple type through the class      *)
(* table (TLC must report CheckIsJuliaIsa violated: Tuple{Int,Int} isa      *)
(* Tuple{Real,Real}); `NoTypeArm` checks Type{X} through the class table   *)
(* (TLC must report CheckIsJuliaIsa violated: Int isa Type{Int});           *)
(* `OwnChainsOnly` numbers the world's own chains alone (TLC must report    *)
(* CheckIsJuliaIsa violated: Tuple{Int,Int} isa Tuple{Real,Real} where no  *)
(* Int is otherwise in the world).                                          *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
    NoTupleArm,     \* Broken: a Tuple type is checked by the class table
    NoTypeArm,      \* Broken: Type{X} is checked by the class table
    OwnChainsOnly   \* Broken: the numbering holds the world's own chains, not its field classes

Ty(n, ps) == [name |-> n, p |-> ps]
AnyT  == Ty("Any", <<>>)
RealT == Ty("Real", <<>>)
IntT  == Ty("Int", <<>>)
FltT  == Ty("Flt", <<>>)
DTT   == Ty("DT", <<>>)
NoneT == Ty("none", <<>>)     \* an instance's `tv`: it is no type value

Params == {IntT, FltT, RealT, AnyT}
ConcreteParams == {IntT, FltT}

DataTypes == Params \cup {DTT}
    \cup {Ty("Vec", <<p>>) : p \in Params} \cup {Ty("AVec", <<p>>) : p \in Params}
    \cup {Ty("Tup", <<p, q>>) : p, q \in Params} \cup {Ty("Type", <<p>>) : p \in Params}

\* Julia's isconcretetype: a leaf, a Vector of any parameter, a Tuple of concrete elements
Concrete(t) ==
    \/ t \in {IntT, FltT, DTT}
    \/ t.name = "Vec"
    \/ t.name = "Tup" /\ \A i \in 1..2 : t.p[i] \in ConcreteParams

ConcreteTypes == {t \in DataTypes : Concrete(t)}

\* Julia's supertype, its parameters bound: none for Any
Super(t) ==
    CASE t.name \in {"Int", "Flt"} -> RealT
      [] t.name = "Vec"            -> Ty("AVec", t.p)
      [] t.name = "Any"            -> AnyT
      [] OTHER                     -> AnyT

RECURSIVE Chain(_)
\* a class and its ancestors, Any last
Chain(t) == IF t = AnyT THEN {AnyT} ELSE {t} \cup Chain(Super(t))

(* ---- the spec: Julia's subtyping of a concrete type S by a DataType T ---- *)
RECURSIVE Sub(_, _)
Sub(s, t) ==
    IF t = AnyT THEN TRUE
    ELSE IF t.name = "Tup" THEN s.name = "Tup" /\ \A i \in 1..2 : Sub(s.p[i], t.p[i])
    ELSE \E a \in Chain(s) : a.name = t.name /\ a.p = t.p

\* jl_isa(o, T): a type value X is an instance of Type{X} and of DT's supertypes
Isa(o, t) ==
    IF o.tv # NoneT THEN (t.name = "Type" /\ t.p[1] = o.tv) \/ Sub(DTT, t)
    ELSE Sub(o.cls, t)

VARIABLES world, o, t
vars == <<world, o, t>>

ClassOf(v) == IF v.tv # NoneT THEN DTT ELSE v.cls

(* ---- the check: dart's _checkInstance arms over Julia's classes ---- *)
\* the classes a class's fields name, which the class walk meets (class_instance_fields): a Tuple's
\* element types, a Vector's element type
FieldTypes(c) == IF c.name \in {"Tup", "Vec"} THEN {c.p[i] : i \in DOMAIN c.p} ELSE {}
\* the closed world's numbered classes: its classes, the classes their fields name, and every
\* ancestor on their chains (`OwnChainsOnly`, Broken: the world's own chains alone)
Numbered == UNION {Chain(c) : c \in world \cup (IF OwnChainsOnly THEN {} ELSE UNION {FieldTypes(w) : w \in world})}
\* the class table (_checkSubclassRelationship): `sup` lies on `sub`'s chain, both numbered
Rel(sub, sup) == sup \in Numbered /\ sup \in Chain(sub)

\* a type-level check of an element type `s` (a concrete class) against `u` (a parameter)
TypeCheck(s, u) == IF u = AnyT THEN TRUE ELSE IF Concrete(u) THEN s = u ELSE s \in Numbered /\ Rel(s, u)

Check(v, u) ==
    IF u = AnyT THEN TRUE
    ELSE IF u.name = "Type" /\ ~NoTypeArm THEN v.tv # NoneT /\ v.tv = u.p[1]
    ELSE IF u.name = "Tup" /\ ~Concrete(u) /\ ~NoTupleArm THEN
        LET s == ClassOf(v) IN s.name = "Tup" /\ \A i \in 1..2 : TypeCheck(s.p[i], u.p[i])
    ELSE IF Concrete(u) THEN ClassOf(v) = u
    ELSE IF u \notin Numbered THEN FALSE
    ELSE Rel(ClassOf(v), u)

Values == {[cls |-> c, tv |-> NoneT] : c \in world} \cup
          (IF DTT \in world THEN {[cls |-> DTT, tv |-> x] : x \in Params} ELSE {})

TypeOK ==
    /\ world \subseteq ConcreteTypes
    /\ t \in DataTypes
    /\ ClassOf(o) \in world

\* the claim: the check answers Julia's isa for every value of the world and every tested type
CheckIsJuliaIsa == Check(o, t) = Isa(o, t)

Init ==
    /\ world \in {w \in SUBSET ConcreteTypes : Cardinality(w) \in 1..3}
    /\ o \in Values
    /\ t \in DataTypes

\* each state is one question; a terminal stutter
Spec == Init /\ [][UNCHANGED vars]_vars
=============================================================================
