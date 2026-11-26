----------------------------- MODULE ConstantKeys -----------------------------
(***************************************************************************)
(* A TLA+ model of the key the program's constants are interned by         *)
(* (src/constants.jl ensureConstant, src/julia/wasm_array.jl StringObject   *)
(* and HeldStrings), over Strings that are objects: dart's constantInfo     *)
(* (constants.dart:154), keyed by value, over Julia's values.               *)
(*                                                                           *)
(* JULIA'S DIFFERENCE, MODELLED. A String is an object whose identity       *)
(* Julia's dataids observes: a const binding's String and a literal of      *)
(* equal contents are two objects natively (Julia roots equal literals as   *)
(* one, julia/src/ircode.c:175 through julia/src/staticdata.c:2987          *)
(* jl_as_global_root). So the key is Same: Julia's ===, except that a        *)
(* String, alone or held through an immutable's fields, is compared by its  *)
(* object. Julia's === itself (julia/src/builtins.c:243 jl_egal__bitstag)    *)
(* compares a String by its contents, and the module's === does the same    *)
(* (src/intrinsics.jl Val(:string_egal)), so constants keyed apart still    *)
(* answer === by contents.                                                   *)
(*                                                                           *)
(* Constants.tla models ensureConstant's interning, eagerness and order     *)
(* over a universe of one object per String, where Same is ===, so its      *)
(* SharesOnlyEgal holds there; this model lifts that abstraction for the    *)
(* key alone. Its ensure and define are Constants.tla's (children first,    *)
(* an info per key, each defined before its parent), every constant eager.  *)
(*                                                                           *)
(* ABSTRACTION. A universe: an integer (a value type); S and S2, Strings of *)
(* equal contents that are two objects; tuples TS and TS2 holding S and S2  *)
(* (egal); BTS2, a struct whose field of type Any holds TS2, which its      *)
(* initializer boxes into the tuple's record from the tuple's own fields    *)
(* (ConstantInstantiator.instantiate); structs P and Pcopy holding S and S2 *)
(* (egal); and two mutable cells holding S. Init picks every program of     *)
(* one or two uses; each use ensures its constant and defines it.           *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   SharesOnlySame two used constants share an info exactly when Same       *)
(*   EgalByContent  the module's === on two used constants is Julia's, a     *)
(*                  String's by its contents whatever its object             *)
(*   ReadsDefined   every constant an eager initializer reads, a boxed       *)
(*                  tuple's own fields among them, has an info, found by its *)
(*                  key, defined before it: none is created inside another's *)
(*                  initializer (dart2wasm/lib/constants.dart:2196's assert) *)
(*   ChildrenFirst  an info's children are defined before it                 *)
(* Broken variants: KeyStringEgal (=== throughout, a String by contents,    *)
(* the key before 43f5f67a: SharesOnlySame), KeyHolderEgal (43f5f67a's key: *)
(* a String by its object, a holder of one by ===, incongruent with its     *)
(* fields' keys: ReadsDefined), RefEqStrings (the module's === on Strings   *)
(* by reference: EgalByContent).                                             *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS KeyStringEgal, KeyHolderEgal, RefEqStrings

Consts == {"I1", "S", "S2", "TS", "TS2", "BTS2", "P", "Pcopy", "M1", "M2"}
ValueTypes == {"I1"}
Strings == {"S", "S2"}
Tuples == {"TS", "TS2"}
Mutable == {"M1", "M2"}
Class(c) == CASE c \in Strings -> "String"
              [] c \in Tuples -> "Tuple{String,Int64}"
              [] c \in {"P", "Pcopy"} -> "P"
              [] c \in Mutable -> "Cell"
              [] OTHER -> c
\* a field: its sub-constant and the wasm kind of its declared type ("i64" a value, "ref" a reference)
F(sub, kind) == [sub |-> sub, kind |-> kind]
Fields(c) == CASE c = "TS" -> <<F("S", "ref"), F("I1", "i64")>>
               [] c = "TS2" -> <<F("S2", "ref"), F("I1", "i64")>>
               [] c = "BTS2" -> <<F("TS2", "ref")>>      \* a field of type Any holding a tuple
               [] c = "P" -> <<F("S", "ref")>>
               [] c = "Pcopy" -> <<F("S2", "ref")>>
               [] c \in Mutable -> <<F("S", "ref")>>
               [] OTHER -> << >>

\* Julia's ===: a String by its contents (one class, no fields here), a mutable by identity, an immutable by its
\* class and its fields' ===
RECURSIVE Egal(_, _)
Egal(x, y) == IF x \in Mutable \/ y \in Mutable THEN x = y
              ELSE Class(x) = Class(y) /\ Len(Fields(x)) = Len(Fields(y)) /\
                   \A i \in 1..Len(Fields(x)) : Egal(Fields(x)[i].sub, Fields(y)[i].sub)
\* the code's key: ===, a String compared by its object wherever it is held (StringObject; HeldStrings'
\* _same_objects through an immutable's fields)
RECURSIVE Same(_, _)
Same(x, y) == IF x \in Mutable \/ y \in Mutable \/ x \in Strings \/ y \in Strings THEN x = y
              ELSE Class(x) = Class(y) /\ Len(Fields(x)) = Len(Fields(y)) /\
                   \A i \in 1..Len(Fields(x)) : Same(Fields(x)[i].sub, Fields(y)[i].sub)
\* 43f5f67a's key: a String by its object, any holder of one by ===
HolderEgal(x, y) == IF x \in Strings \/ y \in Strings THEN x = y ELSE Egal(x, y)
Key(x, y) == IF KeyStringEgal THEN Egal(x, y) ELSE IF KeyHolderEgal THEN HolderEgal(x, y) ELSE Same(x, y)

Range(s) == {s[i] : i \in 1..Len(s)}
Uses == {<<c>> : c \in Consts} \cup {<<c, d>> : c, d \in Consts}
Subs(c) == {Fields(c)[j].sub : j \in 1..Len(Fields(c))} \ ValueTypes

VARIABLES program, st
vars == <<program, st>>

\* the state: info[c] the info a constant maps to (0 none), each info's constant and children, each info's global
\* number (0 undefined), the next number, and the constants each initializer reads, <<info, constant>>
Empty == [info |-> [c \in Consts |-> 0], ofInfo |-> << >>, children |-> << >>, def |-> << >>, nextGlobal |-> 1,
          reads |-> {}]

\* the info a constant already has: one made for a constant its key equates with it
Found(s, c) == {i \in 1..Len(s.ofInfo) : Key(s.ofInfo[i], c)}

\* ensureConstant: a value type none; a known constant its info; else its fields' sub-constants first, then its info
RECURSIVE Ensure(_, _)
RECURSIVE EnsureAll(_, _)
Ensure(s, c) ==
    IF c \in ValueTypes THEN s
    ELSE IF Found(s, c) # {} THEN [s EXCEPT !.info[c] = CHOOSE i \in Found(s, c) : TRUE]
    ELSE LET kids == [j \in 1..Len(Fields(c)) |-> Fields(c)[j].sub]
             s1 == EnsureAll(s, kids)
         IN IF Found(s1, c) # {} THEN [s1 EXCEPT !.info[c] = CHOOSE i \in Found(s1, c) : TRUE]
            ELSE LET id == Len(s1.ofInfo) + 1
                 IN [s1 EXCEPT !.info[c] = id, !.ofInfo = Append(@, c),
                               !.children = Append(@, {s1.info[k] : k \in Subs(c)}), !.def = Append(@, 0)]
EnsureAll(s, kids) == IF kids = << >> THEN s ELSE EnsureAll(Ensure(s, Head(kids)), Tail(kids))

\* the constants the initializer of c reads, each looked up by its key where it is instantiated: each field's
\* sub-constant, and, for a tuple in a field of type Any, the tuple's own fields' sub-constants (the boxing)
BoxedSubs(c) == UNION {Subs(t) : t \in {Fields(c)[j].sub : j \in {k \in 1..Len(Fields(c)) : Fields(c)[k].kind = "ref"}} \cap Tuples}

\* _defineConstantInModuleRecursive: the children first, then the constant, numbered in definition order
RECURSIVE Define(_, _)
RECURSIVE DefineSet(_, _)
DefineOne(s, i) == LET c == s.ofInfo[i] IN
    [s EXCEPT !.def[i] = s.nextGlobal, !.nextGlobal = @ + 1, !.reads = @ \cup {<<i, r>> : r \in Subs(c) \cup BoxedSubs(c)}]
Define(s, i) == IF s.def[i] # 0 THEN s ELSE DefineOne(DefineSet(s, s.children[i]), i)
DefineSet(s, ks) == IF ks = {} THEN s
                    ELSE LET k == CHOOSE x \in ks : \A y \in ks : x <= y
                         IN DefineSet(Define(s, k), ks \ {k})

Use(s, c) == LET s1 == Ensure(s, c) IN IF c \in ValueTypes THEN s1 ELSE Define(s1, s1.info[c])
RECURSIVE Run(_, _)
Run(s, us) == IF us = << >> THEN s ELSE Run(Use(s, Head(us)), Tail(us))

Init == /\ program \in Uses
        /\ st = Run(Empty, program)
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == program \in Uses /\ st.nextGlobal = Len(st.ofInfo) + 1

Used == {c \in Range(program) : c \notin ValueTypes}
Defined == {i \in 1..Len(st.ofInfo) : st.def[i] # 0}
SharesOnlySame == \A x, y \in Used : (st.info[x] = st.info[y]) <=> Same(x, y)
\* the module's === compares the constants the two globals hold, a String's by its length and bytes (RefEqStrings:
\* two Strings by reference)
ModuleEgal(x, y) == IF RefEqStrings /\ x \in Strings /\ y \in Strings THEN st.info[x] = st.info[y]
                    ELSE Egal(st.ofInfo[st.info[x]], st.ofInfo[st.info[y]])
EgalByContent == \A x, y \in Used : ModuleEgal(x, y) = Egal(x, y)
ReadsDefined == \A r \in st.reads : \E i \in Defined : Key(st.ofInfo[i], r[2]) /\ st.def[i] < st.def[r[1]]
ChildrenFirst == \A i \in Defined : \A k \in st.children[i] : st.def[k] # 0 /\ st.def[k] < st.def[i]
=============================================================================
