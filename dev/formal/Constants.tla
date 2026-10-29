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
(* mutable cells of equal contents and a cell holding itself. Init picks     *)
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
(* Broken variants: KeyIsequal (SharesOnlyEgal), ParentFirst (ChildrenFirst),*)
(* IgnoreChildLaziness (EagerChildrenEager), OwnType (a sub-constant at its  *)
(* own type, the 45-case InvalidModule of 2026-10-28: OperandsTyped),        *)
(* NoCycleCheck (CyclesReject).                                              *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS KeyIsequal, ParentFirst, IgnoreChildLaziness, OwnType, NoCycleCheck

\* the universe: each constant's class, mutability, fields (each a sub-constant and the field's kind)
Consts == {"I1", "S", "P", "Pcopy", "Q", "R", "T8", "T64", "Big", "HoldsBig", "M1", "M2", "Mself"}
ValueTypes == {"I1"}
Mutable == {"M1", "M2", "Mself"}
Class(c) == CASE c \in {"P", "Pcopy"} -> "P"
              [] c = "T8" -> "Tuple{UInt8}"
              [] c = "T64" -> "Tuple{Int64}"
              [] c \in {"M1", "M2", "Mself"} -> "Cell"
              [] OTHER -> c
\* a field: its sub-constant and the wasm kind of its declared type ("i64" a value, "ref" a reference)
F(sub, kind) == [sub |-> sub, kind |-> kind]
Fields(c) == CASE c \in {"P", "Pcopy"} -> <<F("I1", "i64")>>
               [] c = "Q" -> <<F("I1", "ref")>>          \* a field of type Any holding an Int
               [] c = "R" -> <<F("P", "ref")>>
               [] c = "T8" -> <<F("I1", "i64")>>
               [] c = "T64" -> <<F("I1", "i64")>>
               [] c = "HoldsBig" -> <<F("Big", "ref")>>
               [] c \in {"M1", "M2"} -> <<F("S", "ref")>>
               [] c = "Mself" -> <<F("Mself", "ref")>>
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
Uses == {<<c>> : c \in Consts} \cup {<<c, d>> : c, d \in Consts}
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
\* way down, a constant met again on it a cycle
RECURSIVE Ensure(_, _, _, _)
RECURSIVE EnsureAll(_, _, _, _)
Ensure(s, c, visiting, fuel) ==
    IF s.outcome # "ok" \/ c \in ValueTypes THEN s
    ELSE IF Found(s, c) # {} THEN [s EXCEPT !.info[c] = CHOOSE i \in Found(s, c) : TRUE]
    ELSE IF ~NoCycleCheck /\ c \in visiting THEN [s EXCEPT !.outcome = "rejected"]
    ELSE IF fuel = 0 THEN [s EXCEPT !.outcome = "overflow"]
    ELSE LET kids == [i \in 1..Len(Fields(c)) |-> Fields(c)[i].sub]
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
\* field's kind (a value boxed into a reference field), or, OwnType, at its own kind
Operand(f) == IF f.sub \in ValueTypes THEN (IF OwnType THEN "i64" ELSE f.kind) ELSE "ref"

\* _defineConstantInModuleRecursive: the children first (ParentFirst: the constant first), then the
\* constant, lazy when it cannot be eager or (IgnoreChildLaziness aside) a child is lazy
RECURSIVE Define(_, _, _)
RECURSIVE DefineSet(_, _, _)
DefineOne(s, i) ==
    LET c == s.ofInfo[i]
        lazy == ~s.eager[i] \/ (~IgnoreChildLaziness /\ \E k \in s.children[i] : s.lazy[k]) \/ ForceLazy(c)
        ops == IF lazy THEN {} ELSE {<<c, j, Operand(Fields(c)[j]), Fields(c)[j].kind>> : j \in 1..Len(Fields(c))}
    IN [s EXCEPT !.def[i] = s.nextGlobal, !.lazy[i] = lazy, !.nextGlobal = @ + 1, !.operands = @ \cup ops]
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
OperandsTyped == Ok => \A o \in st.operands : o[3] = o[4]
CyclesReject == /\ st.outcome # "overflow"
                /\ ("Mself" \in Range(program) => st.outcome = "rejected")
=============================================================================
