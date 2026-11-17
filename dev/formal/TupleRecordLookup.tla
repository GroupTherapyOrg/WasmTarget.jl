-------------------------- MODULE TupleRecordLookup --------------------------
(***************************************************************************)
(* formal(dev/formal/TupleRecordLookup.tla): typeof of a tuple held as its  *)
(* record where the operand's inferred type pins no tuple type (an open     *)
(* slot), answered from its contents (src/intrinsics.jl to_typeof's record  *)
(* arms, the lookup of the world's tuple types).                            *)
(*                                                                           *)
(* STANDS BESIDE TupleRecordTypeof.tla, whose open slot answers the fatal    *)
(* gap. Julia's typeof of a tuple is the tuple type of its elements' types,  *)
(* fixed when the tuple is made (julia/src/builtins.c:946 jl_f_tuple: the    *)
(* type cache's lookup, jltypes.c:1133 lookup_typevalue, or a type made);    *)
(* dart's record computes its runtime type from its fields' runtime types    *)
(* (pkg/dart2wasm/lib/record_class_generator.dart:653                        *)
(* _generateRecordRuntimeType). The port: each field's typeof (a tag's table *)
(* entry, or, for a field that is itself a record, this same lookup), then   *)
(* the world's concrete tuple types of the tuple's arity, each a row of its  *)
(* element types, searched in order: a row equal at every position answers  *)
(* that type's constant; none, or a field whose own typeof is the fatal gap, *)
(* is the fatal gap (a type the program never names, which WasmTarget never  *)
(* makes at run time, audit A68S3).                                          *)
(*                                                                           *)
(* ABSTRACTION. A field is Int64 (I), Float64 (F), or a tuple held as its    *)
(* record: N = (I,), of the type Tuple{Int64}, or P = (F, F), of the type    *)
(* Tuple{Float64,Float64}. A value is a tuple of up to two fields; its       *)
(* Julia type is the sequence of its fields' types (a nested field's type    *)
(* named by its field letter). The world's tuple types, the rows, are closed *)
(* under their fields' types (the walk meets each class's field types): N's  *)
(* Tuple{Int64} is a row, P's Tuple{Float64,Float64} is none. The value is   *)
(* chosen once among all of them; the claims hold of each.                   *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   TypeofAgrees   the lookup answers the value's own type or the fatal     *)
(*                  gap, never another type                                  *)
(*   TypeofAnswers  where the value's type is a row of the world (and so are *)
(*                  its nested fields' types), the lookup answers it          *)
(* Broken variants, each refuted by TypeofAgrees: ArityOnly (a row matching  *)
(* on arity alone answers), FirstRowOnMiss (a miss answers the first row of  *)
(* the arity), NestedFatalIgnored (a field whose typeof is fatal matches any *)
(* row's element: a partial match).                                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    ArityOnly,          \* Broken: a row of the tuple's arity answers whatever its elements
    FirstRowOnMiss,     \* Broken: a miss answers the first row of the arity
    NestedFatalIgnored  \* Broken: a nested field whose typeof is fatal matches any element

Scalars == {"I", "F"}
NestedOf == [e \in {"N", "P"} |-> IF e = "N" THEN <<"I">> ELSE <<"F", "F">>]
Fields  == Scalars \cup DOMAIN NestedOf
\* the world's concrete tuple types, closed under their fields' types; the empty tuple's type is its own constant
World   == {<<"I">>, <<"I", "F">>, <<"F", "I">>, <<"N", "I">>}
Values  == {<<>>} \cup {<<a>> : a \in Fields} \cup {<<a, b>> : a \in Fields, b \in Fields}
Fatal   == <<"fatal">>       \* the whole typeof, the fatal gap
FieldFatal == "fatal"        \* a field's typeof, the fatal gap
Any     == "any"

Rows(n) == {w \in World : Len(w) = n}
\* the rows in a fixed order: the first of the arity
FirstRow(n) == CHOOSE w \in Rows(n) : TRUE

RECURSIVE Lookup(_)
\* a field's typeof: a scalar's tag entry; a nested record's, this lookup of its contents, named by its field letter
FieldType(e) ==
    IF e \in Scalars THEN e
    ELSE IF Lookup(NestedOf[e]) = Fatal THEN (IF NestedFatalIgnored THEN Any ELSE FieldFatal)
    ELSE e
\* the per-field typeofs, then the first row equal at every position; any fatal field, or no row, the fatal gap
Lookup(v) ==
    IF Len(v) = 0 THEN <<>>
    ELSE LET ts == [i \in 1..Len(v) |-> FieldType(v[i])]
             hits == {w \in Rows(Len(v)) : ArityOnly \/ \A i \in 1..Len(v) : ts[i] = Any \/ w[i] = ts[i]}
         IN IF \E i \in 1..Len(v) : ts[i] = FieldFatal THEN Fatal
            ELSE IF hits # {} THEN CHOOSE w \in hits : TRUE
            ELSE IF FirstRowOnMiss /\ Rows(Len(v)) # {} THEN FirstRow(Len(v))
            ELSE Fatal

\* whether the value's type, and each nested field's type, is a type the world names
Named(v) == (Len(v) = 0 \/ v \in World) /\ \A i \in 1..Len(v) : v[i] \in DOMAIN NestedOf => NestedOf[v[i]] \in World

VARIABLE val
Init == val \in Values
Next == UNCHANGED val
Spec == Init /\ [][Next]_val

TypeOK == val \in Values
TypeofAgrees  == Lookup(val) \in {val, Fatal}
TypeofAnswers == Named(val) => Lookup(val) = val
(***************************************************************************)
(* THE LOOKUP AS THE CODE RETURNS IT (the review of the code, S2 and S3).   *)
(* Above, a nested field's type is its letter whenever its own lookup is    *)
(* not fatal, and each arity has one nested type, so a nested lookup that   *)
(* answered the WRONG row of its arity would pass TypeofAgrees. Here the    *)
(* field's type is what the nested lookup RETURNS (named by the letter of   *)
(* the value of that type, "other" where none is), arity 1 has two nested   *)
(* types, M = (F,), of the type Tuple{Float64}, beside N, and a fatal field *)
(* matches no element (the code's null, which ref.eq to no constant), so    *)
(* NestedFatalIgnored is one definition, FieldMatchesR. Broken:             *)
(* NestedFirstRow, a nested lookup answering the first row of its arity.    *)
(***************************************************************************)
CONSTANT NestedFirstRow   \* Broken: a nested field's lookup answers the first row of its arity

NestedOfR == [e \in {"N", "M", "P"} |-> CASE e = "N" -> <<"I">> [] e = "M" -> <<"F">> [] OTHER -> <<"F", "F">>]
FieldsR   == Scalars \cup DOMAIN NestedOfR
\* the world's tuple types: Tuple{Int64} and Tuple{Float64} are rows, Tuple{Float64,Float64} is none; both nested types of arity 1 are elements of a row
WorldR    == {<<"I">>, <<"F">>, <<"I", "F">>, <<"F", "I">>, <<"N", "I">>, <<"M", "I">>}
ValuesR   == {<<>>} \cup {<<a>> : a \in FieldsR} \cup {<<a, b>> : a \in FieldsR, b \in FieldsR}
RowsR(n)  == {w \in WorldR : Len(w) = n}
FirstRowR(n) == CHOOSE w \in RowsR(n) : TRUE
\* the letter naming a type a nested lookup returns: the nested value of that type, or "other" (no value's)
LetterR(t) == IF \E l \in DOMAIN NestedOfR : NestedOfR[l] = t THEN CHOOSE l \in DOMAIN NestedOfR : NestedOfR[l] = t ELSE "other"

RECURSIVE LookupR(_)
\* a field's typeof: a scalar's tag entry; a nested record's, the type its own lookup returns, or the gap
FieldTypeR(e) ==
    IF e \in Scalars THEN e
    ELSE LET r == IF NestedFirstRow /\ RowsR(Len(NestedOfR[e])) # {} THEN FirstRowR(Len(NestedOfR[e])) ELSE LookupR(NestedOfR[e])
         IN IF r = Fatal THEN FieldFatal ELSE LetterR(r)
\* a field's typeof against a row's element: equal, and the gap equal to none
FieldMatchesR(t, el) == IF t = FieldFatal THEN NestedFatalIgnored ELSE el = t
\* the per-field typeofs, then a row matching at every position; none, the fatal gap
LookupR(v) ==
    IF Len(v) = 0 THEN <<>>
    ELSE LET ts == [i \in 1..Len(v) |-> FieldTypeR(v[i])]
             hits == {w \in RowsR(Len(v)) : ArityOnly \/ \A i \in 1..Len(v) : FieldMatchesR(ts[i], w[i])}
         IN IF hits # {} THEN CHOOSE w \in hits : TRUE
            ELSE IF FirstRowOnMiss /\ RowsR(Len(v)) # {} THEN FirstRowR(Len(v))
            ELSE Fatal

NamedR(v) == (Len(v) = 0 \/ v \in WorldR) /\ \A i \in 1..Len(v) : v[i] \in DOMAIN NestedOfR => NestedOfR[v[i]] \in WorldR

\* every value of the extended world, the state's among them (Values is within ValuesR; reading the state, TLC checks
\* each claim as an invariant of every state)
TypeofAgreesR  == \A v \in ValuesR \cup {val} : LookupR(v) \in {v, Fatal}
TypeofAnswersR == \A v \in ValuesR \cup {val} : NamedR(v) => LookupR(v) = v
=============================================================================
