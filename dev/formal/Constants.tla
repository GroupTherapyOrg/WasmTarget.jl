----------------------------- MODULE Constants -------------------------------
(***************************************************************************)
(* A TLA+ model of the program's constants (src/constants.jl), dart's        *)
(* constants.dart over Julia's values:                                       *)
(*   ConstantCreator.ensureConstant (:793): a value type (an integer, a     *)
(*     float) gets no info, materialized where it is read; any other        *)
(*     constant's info is looked up by the constant (constantInfo, keyed by  *)
(*     Julia's === through NirConst's hash and ==), else made: its fields'   *)
(*     sub-constants first, each ensured, then createConstant (:820), which *)
(*     can be eager only when every child can (canBeEager).                  *)
(*   _ConstantAccessor._defineConstantInModuleRecursive (:1978) and         *)
(*     _defineConstantInModule (:2016): the children defined first, then    *)
(*     the constant, lazy when it cannot be eager or a child is lazy, else  *)
(*     an immutable global whose initializer builds it (struct.new over its  *)
(*     fields, each sub-constant instantiated at the field's type,          *)
(*     visitInstanceConstant and visitRecordConstant's generator).           *)
(*                                                                           *)
(* JULIA'S DIFFERENCES, MODELLED. Julia's === keys the map: two immutables   *)
(* of one type with egal fields share an info; isequal is no key ((0x01,)    *)
(* and (1,) are isequal, of two classes). A mutable constant is keyed by its *)
(* identity, so two cells with equal contents are two constants. And a      *)
(* mutable constant can reach itself through its fields, which dart's        *)
(* immutable constant DAG never does: ensureConstant rejects it, located    *)
(* (Unquarantined), as the cycle no constant expression builds, where an     *)
(* unchecked recursion never ends (it overflowed Julia's stack, 2026-10-29). *)
(*                                                                           *)
(* ABSTRACTION. A universe of constants: an integer (a value type), a       *)
(* string, immutable structs (P of an Int, Pcopy egal to P, Q whose field of *)
(* type Any holds an Int, R holding P), two tuples isequal and not egal, a   *)
(* constant its forceLazy makes lazy where it is defined (Big, an array too   *)
(* large to be eager) and a struct holding it, two *)
(* mutable cells of equal contents and a cell holding itself, a cell whose  *)
(* reference field Julia holds no value in (#undef, field_may_be_null) and  *)
(* one whose #undef field Julia's codegen rules out (an Internal rejection  *)
(* in visitInstanceConstant). Dflt is the value a fabricating reader would *)
(* invent for an #undef field; no program uses it. Init picks               *)
(* every program of one or two uses; each use ensures its constant and, if   *)
(* ensured, defines it (global indices in definition order).                 *)
(*                                                                           *)
(* This replaces WT1's Constants (ensure_constant_global!, src/codegen/      *)
(* types.jl, gone), whose mutable constants were never interned.             *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   SharesOnlyEgal     two used constants share an info exactly when egal   *)
(*   ChildrenFirst      an eager global's children are defined before it    *)
(*   EagerChildrenEager an eager global's children are eager                 *)
(*   OperandsTyped      each operand of an eager initializer fits its field *)
(*                      (a value in a reference field boxed)                 *)
(*   CyclesReject       a constant reaching itself rejects, located; no use *)
(*                      recurses past the universe's size                    *)
(*   NoFabrication      an #undef field is the null, no info ever made for a *)
(*                      value it does not hold; one Julia rules out rejects  *)
(*                      (D9)                                                 *)
(*   DeterministicNumbering the globals are numbered 1..n (_nextGlobalId's  *)
(*                      count), and of two used constants the one the       *)
(*                      program uses first, unless its walk reaches the     *)
(*                      other, has the lower number: a function of the      *)
(*                      program, never of the constant's hash               *)
(* Broken variants: KeyIsequal (SharesOnlyEgal), ParentFirst (ChildrenFirst),*)
(* IgnoreChildLaziness (EagerChildrenEager), OwnType (a sub-constant at its  *)
(* own type, the 45-case InvalidModule of 2026-10-28: OperandsTyped),        *)
(* NoCycleCheck (CyclesReject), Fabricate (an #undef field read as a        *)
(* defaulted value, WT1's: NoFabrication), HashOrder (a global numbered by  *)
(* the constant's hash bucket: DeterministicNumbering).                      *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS KeyIsequal, ParentFirst, IgnoreChildLaziness, OwnType, NoCycleCheck, Fabricate, HashOrder

\* the universe: each constant's class, mutability, fields (each a sub-constant and the field's kind)
Consts == {"I1", "S", "P", "Pcopy", "Q", "R", "T8", "T64", "Big", "HoldsBig", "M1", "M2", "Mself", "U", "Ubad", "Dflt"}
Usable == Consts \ {"Dflt"}
ValueTypes == {"I1"}
Mutable == {"M1", "M2", "Mself", "U", "Ubad"}
Class(c) == CASE c \in {"P", "Pcopy"} -> "P"
              [] c = "T8" -> "Tuple{UInt8}"
              [] c = "T64" -> "Tuple{Int64}"
              [] c \in {"M1", "M2", "Mself"} -> "Cell"
              [] OTHER -> c
\* a field: its sub-constant and the wasm kind of its declared type ("i64" a value, "ref" a reference);
\* an #undef field holds no sub-constant (Dflt, what a fabricating reader invents), its nullability
\* Julia's field_may_be_null
F(sub, kind) == [sub |-> sub, kind |-> kind, undef |-> FALSE, nullable |-> TRUE]
Undef(nullable) == [sub |-> "Dflt", kind |-> "ref", undef |-> TRUE, nullable |-> nullable]
Fields(c) == CASE c \in {"P", "Pcopy"} -> <<F("I1", "i64")>>
               [] c = "Q" -> <<F("I1", "ref")>>          \* a field of type Any holding an Int
               [] c = "R" -> <<F("P", "ref")>>
               [] c = "T8" -> <<F("I1", "i64")>>
               [] c = "T64" -> <<F("I1", "i64")>>
               [] c = "HoldsBig" -> <<F("Big", "ref")>>
               [] c \in {"M1", "M2"} -> <<F("S", "ref")>>
               [] c = "Mself" -> <<F("Mself", "ref")>>
               [] c = "U" -> <<F("S", "ref"), Undef(TRUE)>>
               [] c = "Ubad" -> <<Undef(FALSE)>>
               [] OTHER -> << >>
\* the constant's own forceLazy, asked where it is defined (_defineConstantInModule :2060)
ForceLazy(c) == c = "Big"
\* Julia's ===: a value or an immutable by its class and its fields' ===; a mutable by identity
RECURSIVE Egal(_, _)
Egal(x, y) == IF x \in Mutable \/ y \in Mutable THEN x = y
              ELSE Class(x) = Class(y) /\ Len(Fields(x)) = Len(Fields(y)) /\
                   \A i \in 1..Len(Fields(x)) : Egal(Fields(x)[i].sub, Fields(y)[i].sub)
\* isequal: across classes for these tuples (KeyIsequal's key)
IsEq(x, y) == Egal(x, y) \/ ({x, y} = {"T8", "T64"})
Key(x, y) == IF KeyIsequal THEN IsEq(x, y) ELSE Egal(x, y)

Range(s) == {s[i] : i \in 1..Len(s)}
Uses == {<<c>> : c \in Usable} \cup {<<c, d>> : c, d \in Usable}
\* the hash buckets a HashOrder numbering walks: the universe in an order unrelated to discovery
HashSeq == <<"Dflt", "Ubad", "U", "Mself", "M2", "M1", "HoldsBig", "Big", "T64", "T8", "R", "Q", "Pcopy", "P", "S", "I1">>
Hash(c) == CHOOSE i \in 1..Len(HashSeq) : HashSeq[i] = c
Fuel == Cardinality(Consts) + 1

VARIABLES program, st
vars == <<program, st>>

\* the state: infos (each an id; info[c] the id the constant maps to), each info's constant and
\* children, canBeEager; definitions (each info's global index and laziness); the outcome
Empty == [info |-> [c \in Consts |-> 0], ofInfo |-> << >>, eager |-> << >>, children |-> << >>,
          def |-> << >>, lazy |-> << >>, nextGlobal |-> 1, outcome |-> "ok", operands |-> {}]

\* the info a constant already has: one made for a constant its key equates with it
Found(s, c) == {i \in 1..Len(s.ofInfo) : Key(s.ofInfo[i], c)}

\* ensureConstant: a value type none; a known constant its info; else the children first (each
\* ensured), then the info, eager when it can be and every child can; `visiting` the constants on the
\* way down, a constant met again on it a cycle; an #undef field is read as no sub-constant (the
\* null), and one Julia's codegen rules out rejects (Fabricate: read as a defaulted value, Dflt)
Read(f) == Fabricate \/ ~f.undef
Subs(fs) == [i \in 1..Len(fs) |-> fs[i].sub]
RECURSIVE Ensure(_, _, _, _)
RECURSIVE EnsureAll(_, _, _, _)
Ensure(s, c, visiting, fuel) ==
    IF s.outcome # "ok" \/ c \in ValueTypes THEN s
    ELSE IF Found(s, c) # {} THEN [s EXCEPT !.info[c] = CHOOSE i \in Found(s, c) : TRUE]
    ELSE IF ~NoCycleCheck /\ c \in visiting THEN [s EXCEPT !.outcome = "rejected"]
    ELSE IF fuel = 0 THEN [s EXCEPT !.outcome = "overflow"]
    ELSE IF ~Fabricate /\ \E i \in 1..Len(Fields(c)) : Fields(c)[i].undef /\ ~Fields(c)[i].nullable
         THEN [s EXCEPT !.outcome = "rejected"]
    ELSE LET kids == Subs(SelectSeq(Fields(c), Read))
             s1 == EnsureAll(s, kids, visiting \cup {c}, fuel - 1)
         IN IF s1.outcome # "ok" THEN s1
            ELSE IF Found(s1, c) # {} THEN [s1 EXCEPT !.info[c] = CHOOSE i \in Found(s1, c) : TRUE]
            ELSE LET id == Len(s1.ofInfo) + 1
                     ch == {s1.info[k] : k \in {x \in Range(kids) : x \notin ValueTypes}}
                     eager == \A k \in ch : s1.eager[k]
                 IN [s1 EXCEPT !.info[c] = id, !.ofInfo = Append(@, c), !.eager = Append(@, eager),
                               !.children = Append(@, ch), !.def = Append(@, 0), !.lazy = Append(@, FALSE)]
EnsureAll(s, kids, visiting, fuel) ==
    IF kids = << >> THEN s ELSE EnsureAll(Ensure(s, Head(kids), visiting, fuel), Tail(kids), visiting, fuel)

\* the operands an eager initializer pushes for c's fields: each sub-constant instantiated at the
\* field's kind (a value boxed into a reference field), or, OwnType, at its own kind; an #undef field
\* the null
Operand(f) == IF ~Read(f) THEN "null"
              ELSE IF f.sub \in ValueTypes THEN (IF OwnType THEN "i64" ELSE f.kind) ELSE "ref"

\* _defineConstantInModuleRecursive: the children first (ParentFirst: the constant first), then the
\* constant, lazy when it cannot be eager or (IgnoreChildLaziness aside) a child is lazy
RECURSIVE Define(_, _, _)
RECURSIVE DefineSet(_, _, _)
DefineOne(s, i) ==
    LET c == s.ofInfo[i]
        lazy == ~s.eager[i] \/ (~IgnoreChildLaziness /\ \E k \in s.children[i] : s.lazy[k]) \/ ForceLazy(c)
        ops == IF lazy THEN {} ELSE {<<c, j, Operand(Fields(c)[j]), Fields(c)[j].kind>> : j \in 1..Len(Fields(c))}
        n == IF HashOrder THEN Hash(c) ELSE s.nextGlobal
    IN [s EXCEPT !.def[i] = n, !.lazy[i] = lazy, !.nextGlobal = @ + 1, !.operands = @ \cup ops]
Define(s, i, fuel) ==
    IF s.def[i] # 0 \/ fuel = 0 THEN s
    ELSE IF ParentFirst THEN DefineSet(DefineOne(s, i), s.children[i], fuel - 1)
    ELSE DefineOne(DefineSet(s, s.children[i], fuel - 1), i)
DefineSet(s, ks, fuel) == IF ks = {} THEN s
                          ELSE LET k == CHOOSE x \in ks : \A y \in ks : x <= y
                               IN DefineSet(Define(s, k, fuel), ks \ {k}, fuel)

\* one use: ensured, then defined when it has an info
Use(s, c) == LET s1 == Ensure(s, c, {}, Fuel) IN
             IF s1.outcome # "ok" \/ c \in ValueTypes THEN s1 ELSE Define(s1, s1.info[c], Fuel)
RECURSIVE Run(_, _)
Run(s, us) == IF us = << >> THEN s ELSE Run(Use(s, Head(us)), Tail(us))

Init == /\ program \in Uses
        /\ st = Run(Empty, program)
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == program \in Uses /\ st.outcome \in {"ok", "rejected", "overflow"}

Used == {c \in Range(program) : c \notin ValueTypes}
Ok == st.outcome = "ok"
SharesOnlyEgal == Ok => \A x, y \in Used : (st.info[x] = st.info[y]) <=> Egal(x, y)
ChildrenFirst == Ok => \A i \in 1..Len(st.ofInfo) : st.def[i] # 0 /\ ~st.lazy[i] =>
                     \A k \in st.children[i] : st.def[k] # 0 /\ st.def[k] < st.def[i]
EagerChildrenEager == Ok => \A i \in 1..Len(st.ofInfo) : st.def[i] # 0 /\ ~st.lazy[i] =>
                          \A k \in st.children[i] : ~st.lazy[k]
OperandsTyped == Ok => \A o \in st.operands : o[3] = o[4] \/ (o[3] = "null" /\ o[4] = "ref")
CyclesReject == /\ st.outcome # "overflow"
                /\ ("Mself" \in Range(program) => st.outcome = "rejected")
\* no info for a value no field holds, each #undef field's operand the null, and an #undef field
\* Julia's codegen rules out a rejection, never a value
NoFabrication == /\ Ok => /\ st.info["Dflt"] = 0
                         /\ \A o \in st.operands : Fields(o[1])[o[2]].undef => o[3] = "null"
                 /\ ("Ubad" \in Range(program) => st.outcome = "rejected")
\* the ground truth, from the program and the universe alone: where the program first uses a constant
\* or one egal to it, and whether a constant's walk (its fields' sub-constants, as Ensure reads them)
\* reaches one egal to another
Pos(c) == CHOOSE i \in 1..Len(program) : Egal(program[i], c) /\ \A j \in 1..(i - 1) : ~Egal(program[j], c)
Kids(c) == {k \in Range(Subs(SelectSeq(Fields(c), Read))) : k \notin ValueTypes}
RECURSIVE Reaches(_, _, _)
Reaches(x, y, fuel) == Egal(x, y) \/ (fuel > 0 /\ \E k \in Kids(x) : Reaches(k, y, fuel - 1))
Defined == {i \in 1..Len(st.ofInfo) : st.def[i] # 0}
\* the globals numbered 1..n, and a constant the program uses first numbered first unless its walk
\* defines the other
DeterministicNumbering == Ok => /\ {st.def[i] : i \in Defined} = 1..Cardinality(Defined)
                                /\ \A x, y \in Used : Pos(x) < Pos(y) /\ ~Reaches(x, y, Fuel) =>
                                       st.def[st.info[x]] < st.def[st.info[y]]
=============================================================================
