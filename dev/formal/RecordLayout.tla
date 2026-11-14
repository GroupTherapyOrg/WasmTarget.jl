-------------------------- MODULE RecordLayout --------------------------------
(***************************************************************************)
(* A TLA+ model of a record's layout: RecordShape, RecordShape.fromType, its *)
(* == and getNameIndex/getPositionalIndex (src/records.jl, dart's            *)
(* records.dart:13-78).                                                      *)
(*   RecordShape(positionals, names): each name to its position after the   *)
(*     positionals, the pairs ordered by name.                               *)
(*   fromType: a NamedTuple type its declared names, no positionals; a Tuple *)
(*     type one positional per parameter; a tuple type whose length or names *)
(*     Julia leaves open (a Vararg, NamedTuple{N} with N unknown) rejects,   *)
(*     located.                                                              *)
(*   ==: the positionals, then each name with its index.                    *)
(*   getNameIndex / getPositionalIndex: the record field base plus the       *)
(*     name's index, or the position.                                        *)
(* dart sorts a record's named fields, so its == compares the names alone   *)
(* and a name's index follows from them. A Julia NamedTuple keeps its       *)
(* declared order and lays its fields out in it, (b = 1, a = 2) holding b   *)
(* first, so a shape is its names with their indices, and two orders are    *)
(* two shapes (A42S3, A45S2).                                                *)
(*                                                                           *)
(* ABSTRACTION. Record types are every NamedTuple of up to three distinct    *)
(* names, every Tuple of up to two parameters, and two open ones; a shape is *)
(* the set of its (name, index) pairs with its positional count (the        *)
(* code's list ordered by name holds the same pairs, and its == compares    *)
(* them pairwise, which for distinct names is equality of the sets). Init   *)
(* picks every pair of record types; nothing steps.                          *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   IndexIsPlace      a name's index is its declared place, the field       *)
(*                     Julia's layout holds it in                            *)
(*   EqualIsLayout     two shapes are == exactly when the indices they give  *)
(*                     every field agree                                     *)
(*   OpenRejects       a type of open length or names has no shape           *)
(* Broken variants: SortedIndex (dart's index by sorted place:               *)
(* IndexIsPlace), NamesOnly (dart's ==, the names alone: EqualIsLayout),     *)
(* OpenAsEmpty (an open type given the empty shape: OpenRejects).            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    SortedIndex,  \* Broken: a name's index is its place among the sorted names
    NamesOnly,    \* Broken: == compares the names alone
    OpenAsEmpty   \* Broken: an open tuple type takes the empty shape

Names == {"a", "b", "c"}
Base0 == 1        \* FieldIndex.recordFieldBase: the header field before the record's

Range(q) == {q[i] : i \in 1..Len(q)}
Distinct(q) == \A i, j \in 1..Len(q) : i # j => q[i] # q[j]
NameSeqs == {q \in UNION {[1..n -> Names] : n \in 0..3} : Distinct(q)}

\* record types: a NamedTuple of declared names, a Tuple of a parameter count, an open one
NT(q)  == [kind |-> "named", names |-> q, n |-> 0]
Tup(n) == [kind |-> "tuple", names |-> <<>>, n |-> n]
Open(k) == [kind |-> k, names |-> <<>>, n |-> 0]
RecordTypes == {NT(q) : q \in NameSeqs} \cup {Tup(n) : n \in 0..2} \cup {Open("vararg"), Open("opennames")}

\* a positional field's name in the layout, so a layout is a set of (name, index) pairs alike
PosName(i) == CASE i = 0 -> "$0" [] i = 1 -> "$1"

\* the declared layout: field i of the type sits at Base0 + i - 1
Layout(rt) == IF rt.kind = "named"
              THEN [i \in 1..Len(rt.names) |-> <<rt.names[i], Base0 + i - 1>>]
              ELSE [i \in 1..rt.n |-> <<PosName(i - 1), Base0 + i - 1>>]

\* the place of a name among the names sorted, by code point
Less(x, y) == (x = "a" /\ y # "a") \/ (x = "b" /\ y = "c")
RankOf(q, x) == Cardinality({y \in Range(q) : Less(y, x)})

NoShape == [positionals |-> 0, pairs |-> {}, none |-> TRUE]
Shape(positionals, q) ==
    [positionals |-> positionals,
     pairs |-> {<<q[i], IF SortedIndex THEN RankOf(q, q[i]) + positionals ELSE i - 1 + positionals>> :
                i \in 1..Len(q)},
     none |-> FALSE]
FromType(rt) == CASE rt.kind = "named" -> Shape(0, rt.names)
                  [] rt.kind = "tuple" -> Shape(rt.n, <<>>)
                  [] OTHER             -> IF OpenAsEmpty THEN Shape(0, <<>>) ELSE NoShape

Eq(s1, s2) == /\ s1.positionals = s2.positionals
              /\ IF NamesOnly THEN {p[1] : p \in s1.pairs} = {p[1] : p \in s2.pairs}
                 ELSE s1.pairs = s2.pairs

NameIndex(s, x) == Base0 + (CHOOSE p \in s.pairs : p[1] = x)[2]
PositionalIndex(s, i) == Base0 + i

\* where the shape puts each field of the type: names by getNameIndex, positionals by
\* getPositionalIndex
Placed(rt) == LET s == FromType(rt) IN
    IF rt.kind = "named" THEN {<<x, NameIndex(s, x)>> : x \in Range(rt.names)}
    ELSE {<<PosName(i), PositionalIndex(s, i)>> : i \in 0..(s.positionals - 1)}

VARIABLES r1, r2
vars == <<r1, r2>>

TypeOK == r1 \in RecordTypes /\ r2 \in RecordTypes
Init == r1 \in RecordTypes /\ r2 \in RecordTypes
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

Shaped(rt) == rt.kind \in {"named", "tuple"}

IndexIsPlace  == Shaped(r1) => Placed(r1) = Range(Layout(r1))
EqualIsLayout == Shaped(r1) /\ Shaped(r2) =>
                     (Eq(FromType(r1), FromType(r2)) <=> Placed(r1) = Placed(r2))
OpenRejects   == ~Shaped(r1) => FromType(r1).none
=============================================================================
