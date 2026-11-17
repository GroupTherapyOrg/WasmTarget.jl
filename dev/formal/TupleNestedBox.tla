---------------------------- MODULE TupleNestedBox ----------------------------
(***************************************************************************)
(* formal(dev/formal/TupleNestedBox.tla): convertType's box of a concrete   *)
(* tuple into its record and its unbox back (src/translator.jl convert_type),*)
(* where a tuple's fields are tuples: one generated function per tuple type  *)
(* with a boxable tuple field (TupleBoxReference), which boxes each tuple    *)
(* field by that field type's own function or inline arm, against the deep   *)
(* box the inline arm wrote (each field's box inlined, 2^depth copies).      *)
(*                                                                           *)
(* Julia boxes an immutable holding immutables flat: one allocation, one     *)
(* copy of the inline value (julia/src/cgutils.cpp:3794 boxed, :3975         *)
(* emit_allocobj, :3404 init_bits_cgval). A record's fields are top-typed,  *)
(* so WasmTarget's box of a nested tuple is a record per level; the claim is *)
(* that the per-type functions build the same representation the deep box  *)
(* builds, and that the unbox gives back the concrete structs.               *)
(*                                                                           *)
(* ABSTRACTION. A type is <<>> (a scalar, boxed at the top) or a tuple of one*)
(* or two types, up to depth 3. A value's concrete representation is its    *)
(* struct, a tuple field holding the field's own struct; its top            *)
(* representation is its record, a tuple field holding the field's record,  *)
(* a scalar field its box. HasTupleField, the one predicate, decides which  *)
(* tuple types get a function; any other tuple type is boxed inline.         *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   BoxAgrees    the box through the functions is the deep box             *)
(*   UnboxAgrees  the unbox of the deep box is the concrete struct          *)
(* Broken variants: ShallowBox (a function keeps a tuple field's struct in  *)
(* the record: BoxAgrees), ShallowUnbox (the unbox keeps a tuple field's    *)
(* record in the struct: UnboxAgrees).                                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    ShallowBox,     \* Broken: a box function leaves a tuple field's struct in the record
    ShallowUnbox    \* Broken: an unbox function leaves a tuple field's record in the struct

RECURSIVE TypesOf(_)
TypesOf(d) == IF d = 0 THEN {<<>>} ELSE
    LET prev == TypesOf(d - 1) IN prev \cup {<<a>> : a \in prev} \cup {<<a, b>> : a \in prev, b \in prev}
TupleTypes == TypesOf(3) \ {<<>>}

IsTuple(t) == Len(t) > 0
\* the one predicate: a tuple type with a tuple field gets a box function; any other tuple type is boxed inline
HasTupleField(t) == \E i \in 1..Len(t) : IsTuple(t[i])

\* a scalar's representations, unboxed in a struct and boxed at the top (every representation a record of one shape)
Scalar == [k |-> "scalar", ty |-> <<>>, f |-> <<>>]
Boxed  == [k |-> "boxed", ty |-> <<>>, f |-> <<>>]

RECURSIVE Conc(_), Top(_)
\* the concrete struct of a value of type t: a tuple field holds the field's own struct
Conc(t) == IF IsTuple(t) THEN [k |-> "struct", ty |-> t, f |-> [i \in 1..Len(t) |-> Conc(t[i])]] ELSE Scalar
\* the top representation, the deep box: a tuple field holds the field's record, a scalar its box
Top(t)  == IF IsTuple(t) THEN [k |-> "record", ty |-> <<>>, f |-> [i \in 1..Len(t) |-> Top(t[i])]] ELSE Boxed

RECURSIVE Box(_), BoxFn(_)
\* the box at a site: the type's function where HasTupleField, else the inline arm (its scalar fields boxed)
Box(t) == IF HasTupleField(t) THEN BoxFn(t) ELSE [k |-> "record", ty |-> <<>>, f |-> [i \in 1..Len(t) |-> Boxed]]
\* the function: each tuple field by its own type's box (function or inline), each scalar field boxed
BoxFn(t) == [k |-> "record", ty |-> <<>>, f |-> [i \in 1..Len(t) |->
                 IF IsTuple(t[i]) THEN (IF ShallowBox THEN Conc(t[i]) ELSE Box(t[i])) ELSE Boxed]]

RECURSIVE Unbox(_, _), UnboxFn(_, _)
\* the unbox of a record into the type's struct: the type's function where HasTupleField, else the inline arm
Unbox(t, r) == IF HasTupleField(t) THEN UnboxFn(t, r) ELSE [k |-> "struct", ty |-> t, f |-> [i \in 1..Len(t) |-> Scalar]]
UnboxFn(t, r) == [k |-> "struct", ty |-> t, f |-> [i \in 1..Len(t) |->
                     IF IsTuple(t[i]) THEN (IF ShallowUnbox THEN r.f[i] ELSE Unbox(t[i], r.f[i])) ELSE Scalar]]

\* the state names one type; the claims read it, so TLC checks them as invariants of every state, over every type
VARIABLE ty
Init == ty \in TupleTypes
Next == UNCHANGED ty
Spec == Init /\ [][Next]_ty

TypeOK      == ty \in TupleTypes
BoxAgrees   == \A t \in TupleTypes \cup {ty} : Box(t) = Top(t)
UnboxAgrees == \A t \in TupleTypes \cup {ty} : Unbox(t, Top(t)) = Conc(t)
=============================================================================
