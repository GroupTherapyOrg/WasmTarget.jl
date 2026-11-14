--------------------------- MODULE ClassIdNumbering ---------------------------
(***************************************************************************)
(* A TLA+ model of the class ids and their ranges (src/class_info.jl):       *)
(*   ClassIdNumbering._number (class_info.dart:864): the closed world's      *)
(*     classes (closed_world_classes), each class's subclasses by Julia's    *)
(*     supertype and its implementors by class_implemented_types; a depth-   *)
(*     first pre-order walk from Any giving a concrete class the next        *)
(*     concrete id (from 1) and an abstract class the next abstract id (from *)
(*     one past the last concrete), each class's concrete subclass range     *)
(*     [the concrete counter at its pre, the counter less one at its post];  *)
(*   _getTransitiveImplementors (:805), getConcreteClassIdRange (:831) and   *)
(*   normalize (:1093): a class's ranges, its own and its transitive         *)
(*     implementors', sorted and merged.                                     *)
(* Julia answers every edge (D3): a class's parent is its supertype; what   *)
(* dart's interfaces give, a subtype off the superclass tree, is Julia's     *)
(* covariant Tuple (Tuple{Int} <: Tuple{Any}, whose supertype is Any), so a *)
(* concrete class implements every class of the world it is a subtype of    *)
(* off its supertype chain.                                                  *)
(*                                                                           *)
(* THE SPECIFICATION is Julia's isa: a class's ranges hold exactly the ids  *)
(* of the concrete classes Julia's <: puts under it (RangeIsa), so a class-  *)
(* id range test answers isa.                                                *)
(*                                                                           *)
(* ABSTRACTION. A universe of Any, Number, Int, Str and the tuples          *)
(* Tuple{Any} (abstract), Tuple{Int} and Tuple{Str} (concrete), with Julia's *)
(* <: as a fixed operator; Init picks every world (closed under supertype   *)
(* and a tuple's element, as the class walk makes it) and every order the   *)
(* walk can meet its classes in, which orders each class's children.        *)
(*                                                                           *)
(* This replaces WT1's ClassIdNumbering, which held a class's ranges to be  *)
(* its subtree's one range because Julia has no interfaces: Julia's         *)
(* covariant Tuples are dart's implementors, and the port reads them.       *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   ConcreteDense  the concrete classes take 1..C, each once                *)
(*   AbstractAfter  the abstract classes take C+1..C+A, each once            *)
(*   RangeIsa       a class's ranges hold exactly its concrete subtypes' ids *)
(*   Normalized     a class's ranges are sorted, disjoint and not adjacent   *)
(* Broken variants: SharedCounter (one counter for both: ConcreteDense),     *)
(* OffByOne (a range ends at the counter, not one before: RangeIsa),         *)
(* NoImplementors (WT1's premise, no implemented types: RangeIsa),           *)
(* NoAdjacentMerge (normalize merges overlaps only: Normalized).             *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS SharedCounter, OffByOne, NoImplementors, NoAdjacentMerge

U == {"Any", "Number", "Int", "Str", "TAny", "TInt", "TStr"}
Tuples == {"TAny", "TInt", "TStr"}
Concrete == {"Int", "Str", "TInt", "TStr"}
Super(c) == CASE c = "Int" -> "Number" [] OTHER -> "Any"
Elem(t) == CASE t = "TAny" -> "Any" [] t = "TInt" -> "Int" [] t = "TStr" -> "Str"
RECURSIVE ChainOf(_)
ChainOf(c) == IF c = "Any" THEN {} ELSE {Super(c)} \cup ChainOf(Super(c))
\* Julia's <: over the universe: the supertype chain, and a Tuple's covariance
Le(c, k) == c = k \/ k \in ChainOf(c) \/ (c \in Tuples /\ k \in Tuples /\ (Elem(c) = Elem(k) \/ Elem(k) \in ChainOf(Elem(c))))

Closed(S) == "Any" \in S /\ \A c \in S : (c # "Any" => Super(c) \in S) /\ (c \in Tuples => Elem(c) \in S)
Worlds == {S \in SUBSET U : Closed(S)}

VARIABLES world, rank
vars == <<world, rank>>

Others == world \ {"Any"}
Init ==
    /\ world \in Worlds
    /\ rank \in {r \in [Others -> 1..Cardinality(Others)] : \A a, b \in Others : a # b => r[a] # r[b]}

Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Range(s) == {s[i] : i \in 1..Len(s)}

Kids(k) == {c \in Others : Super(c) = k}
RECURSIVE ByRank(_)
ByRank(S) == IF S = {} THEN << >>
             ELSE LET m == CHOOSE c \in S : \A d \in S : rank[c] <= rank[d] IN <<m>> \o ByRank(S \ {m})
RECURSIVE CatPre(_)
RECURSIVE Pre(_)
Pre(k) == <<k>> \o CatPre(ByRank(Kids(k)))
CatPre(s) == IF s = << >> THEN << >> ELSE Pre(Head(s)) \o CatPre(Tail(s))

\* the walk's pre-order and its counters
Order == Pre("Any")
Pos(c) == CHOOSE i \in 1..Len(Order) : Order[i] = c
IsConc(c) == c \in Concrete
ConcBefore(i) == Cardinality({j \in 1..(i - 1) : IsConc(Order[j])})
AbsBefore(i) == Cardinality({j \in 1..(i - 1) : ~IsConc(Order[j])})
C == Cardinality(world \cap Concrete)
A == Cardinality(world \ Concrete)
Id(c) == IF SharedCounter THEN Pos(c)
         ELSE IF IsConc(c) THEN ConcBefore(Pos(c)) + 1 ELSE C + AbsBefore(Pos(c)) + 1

RECURSIVE Subtree(_)
Subtree(k) == {k} \cup UNION {Subtree(c) : c \in Kids(k)}
\* the range the post writes: the concrete counter at the pre, the counter less one at the post
Last(k) == Max({Pos(c) : c \in Subtree(k)})
SubRange(k) == LET lo == ConcBefore(Pos(k)) + 1
                   hi == ConcBefore(Last(k) + 1) + (IF OffByOne THEN 1 ELSE 0)
               IN IF hi < lo THEN << >> ELSE <<<<lo, hi>>>>

Impl(c) == IF NoImplementors \/ ~IsConc(c) THEN {}
           ELSE {t \in world : t # c /\ t \notin ChainOf(c) /\ Le(c, t)}
Implementors(k) == {c \in world : k \in Impl(c)}
RECURSIVE TI(_)
TI(k) == UNION {TI(s) : s \in Kids(k)} \cup UNION {{c} \cup TI(c) : c \in Implementors(k)}

\* normalize: sorted by start, a range contained, overlapping or adjacent merged
RECURSIVE SortR(_)
SortR(S) == IF S = {} THEN << >>
            ELSE LET m == CHOOSE r \in S : \A q \in S : r[1] <= q[1] /\ (r[1] = q[1] => r[2] <= q[2])
                 IN <<m>> \o SortR(S \ {m})
RECURSIVE Merge(_, _)
Merge(cur, rest) ==
    IF rest = << >> THEN <<cur>>
    ELSE LET nx == Head(rest) IN
         IF nx[1] >= cur[1] /\ nx[2] <= cur[2] THEN Merge(cur, Tail(rest))
         ELSE IF nx[1] <= cur[2] \/ (~NoAdjacentMerge /\ cur[2] + 1 = nx[1])
              THEN Merge(<<cur[1], nx[2]>>, Tail(rest))
              ELSE <<cur>> \o Merge(nx, Tail(rest))
Normalize(rs) == LET s == SortR(rs) IN IF s = << >> THEN << >> ELSE Merge(Head(s), Tail(s))
ClassRanges(k) == Normalize(UNION {Range(SubRange(x)) : x \in {k} \cup TI(k)})

Covered(rs) == UNION {r[1]..r[2] : r \in Range(rs)}

TypeOK == world \in Worlds /\ rank \in [Others -> Nat]

ConcreteDense == {Id(c) : c \in world \cap Concrete} = 1..C /\
                 \A a, b \in world \cap Concrete : a # b => Id(a) # Id(b)
AbstractAfter == {Id(c) : c \in world \ Concrete} = (C + 1)..(C + A) /\
                 \A a, b \in world \ Concrete : a # b => Id(a) # Id(b)
RangeIsa == \A k \in world : Covered(ClassRanges(k)) = {Id(c) : c \in {x \in world \cap Concrete : Le(x, k)}}
Normalized == \A k \in world : LET rs == ClassRanges(k) IN
                  \A i \in 1..(Len(rs) - 1) : rs[i][2] + 1 < rs[i + 1][1]
=============================================================================
