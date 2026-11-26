--------------------------- MODULE TypesEqualSplit ---------------------------
(***************************************************************************)
(* A TLA+ model of Julia's type equality answered at run time where an     *)
(* operand is known only there (src/intrinsics.jl, the types_equal arm,    *)
(* over src/julia/classes.jl types_equal_cache), against Julia's own       *)
(* answer.                                                                 *)
(*                                                                         *)
(* JULIA. `==` of two types is the runtime's jl_types_equal                *)
(* (julia/src/subtype.c:2353): identity, egal, obviously_unequal (:436),   *)
(* then mutual subtyping. It is no identity: two distinct types can be     *)
(* equal (TypeofBottom and its supertype Type{Union{}}, :438-441).         *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. At compile time the cache is made whole: the   *)
(* first operand's values are its members' (a literal's one, or the        *)
(* Type{X} members of the union Julia inferred for it); the second's are   *)
(* the same where it is narrow, and every DataType the program holds where *)
(* it is typed DataType (wide). Narrow, every key one split of the         *)
(* operands' unions, answered by Julia's own jl_types_equal at compile     *)
(* time, the entries in any order. Wide, each left value a gets two        *)
(* entries: <<a, a>> answering true, then <<a, Rest>> answering false,     *)
(* Rest matching any value; and only for an a of the identity premise,     *)
(* every value equal to a is a itself (obviously_unequal's answer for a    *)
(* concrete non-tuple or parameterless DataType, jltypes.c:1354            *)
(* jl_type_equality_is_identity), else the statement rejects, located.     *)
(* At run time the entries are tested in order, the first matching         *)
(* answering; past the last the lookup traps.                              *)
(*                                                                         *)
(* THE CLAIMS. Where the statement compiles, for every pair of values the  *)
(* operands can hold, under every order of the left values or keys:        *)
(* Total, the lookup never traps; Agrees, its answer is Julia's            *)
(* jl_types_equal of the pair.                                             *)
(*                                                                         *)
(* BROKEN. RestFirst: the remainder entry precedes its exact one, so a     *)
(* value equal to a answers false (breaks Agrees). NoPremise: a remainder  *)
(* entry is made for a left value equal to another value than itself      *)
(* (breaks Agrees).                                                        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    Vals,       \* the type values the program can hold
    Eq,         \* Julia's jl_types_equal: a set of ordered pairs, an equivalence over Vals
    Left,       \* the first operand's values, each a key of its own
    Right,      \* the second operand's values where it is narrow
    Wide,       \* BOOLEAN: the second operand is typed DataType, its values all of Vals
    RestFirst,  \* BOOLEAN: the remainder entry precedes its exact one
    NoPremise   \* BOOLEAN: remainder entries made without the identity premise

Rest == "rest"

VARIABLE entries  \* the cache: a sequence of <<left key, right key, answer>>

EqB(a, b) == <<a, b>> \in Eq
RightVals == IF Wide THEN Vals ELSE Right
\* every pair of values the operands can hold at run time
Pairs == Left \X RightVals
\* types_equal_is_identity: every value equal to a is a itself
Identity(a) == \A y \in Vals : EqB(a, y) <=> a = y
\* the statement rejects at compile time, located, where a wide entry lacks its premise
Rejected == Wide /\ ~NoPremise /\ \E a \in Left : ~Identity(a)

Perms(S) == {s \in [1..Cardinality(S) -> S] : \A i, j \in 1..Cardinality(S) : i # j => s[i] # s[j]}

Group(a) == IF RestFirst THEN << <<a, Rest, FALSE>>, <<a, a, TRUE>> >>
                         ELSE << <<a, a, TRUE>>, <<a, Rest, FALSE>> >>
RECURSIVE Groups(_)
Groups(order) == IF order = <<>> THEN <<>> ELSE Group(Head(order)) \o Groups(Tail(order))

\* every cache the code can make: wide, the groups of the left values in any order; narrow, the
\* keys in any order, each answered by Julia's jl_types_equal
Caches == IF Wide THEN {Groups(o) : o \in Perms(Left)}
          ELSE {[i \in 1..Cardinality(Pairs) |-> <<o[i][1], o[i][2], EqB(o[i][1], o[i][2])>>] : o \in Perms(Pairs)}

Match(e, k) == e[1] = k[1] /\ (e[2] = k[2] \/ e[2] = Rest)
Hits(k) == {i \in DOMAIN entries : Match(entries[i], k)}
Min(S) == CHOOSE i \in S : \A x \in S : i <= x

TypeOK == entries \in Caches

Init == entries \in Caches
Next == UNCHANGED entries
Spec == Init /\ [][Next]_entries

Total == ~Rejected => \A k \in Pairs : Hits(k) # {}
Agrees == ~Rejected => \A k \in Pairs : Hits(k) # {} => entries[Min(Hits(k))][3] = EqB(k[1], k[2])
=============================================================================
