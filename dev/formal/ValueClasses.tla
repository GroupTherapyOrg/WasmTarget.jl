-------------------------- MODULE ValueClasses --------------------------------
(***************************************************************************)
(* A TLA+ model of the closed world's classes: closed_world_classes,         *)
(* _meet_value! and _meet_class! (src/julia/classes.jl), the list class_info *)
(* numbers (class_info.jl's ClassIdNumbering, dart's class_info.dart:864     *)
(* walk of the component's classes).                                         *)
(*   closed_world_classes: each body's argument types, statement types, the *)
(*     types of the literals and constant bindings it reads, and its return  *)
(*     type, each met as a value's type; and each constant's object graph:   *)
(*     a literal's or a binding's value, then every value it holds (a        *)
(*     field's, an svec's element), each object walked once (_meet_constant!)*)
(*     and its class met, since constants.jl instantiates each one.          *)
(*   _meet_value!: Union{} brings nothing; a Union its members; a Vararg its *)
(*     element; Type{X} its kind, typeof(X), and the classes X denotes (X, or *)
(*     each member of a Union X); Type{T} with T unknown, or a UnionAll under *)
(*     Type, every kind; a DataType itself.                                  *)
(*   _meet_class!: a class met once (seen); it brings its supertype, then a  *)
(*     kind's instance fields, or a concrete class's field types, each met   *)
(*     as a value's type.                                                    *)
(* dart reads its class list from the component; a Julia program declares   *)
(* none, so its list is the types Julia inferred for its values (D3), and   *)
(* every class a value can have must be on it: class_info numbers only these,*)
(* and a value of a class it never numbered has no classId.                 *)
(*                                                                           *)
(* ABSTRACTION. Types are tokens with Julia's answers as fixed operators:   *)
(* Supertype, IsConcrete, IsKind, the field types of a concrete class and a *)
(* kind's instance fields. Node is recursive (its field Union{Node,         *)
(* Nothing}), so the walk's seen set is what ends it. A program is the       *)
(* sequence of value types the walk reads (where in a body each came from    *)
(* does not change the claims); Init picks every program of one or two of   *)
(* them. The recursion is an explicit stack of meet tasks, a supertype      *)
(* pushed before the fields, as the code calls them.                        *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   Once             no class is listed twice                               *)
(*   ValuesCovered    every class a value of the program can have is listed, *)
(*                    a type value's denoted classes included                *)
(*   SupertypeClosed  every listed class but Any has its supertype listed    *)
(*   FieldsClosed     every listed concrete class has its fields' classes    *)
(*                    listed, a kind its instance fields'                    *)
(*   NothingExtra     every listed class is required by the above            *)
(*   Terminates       the walk ends                                          *)
(* Broken variants: NoSeenGuard (Once), KindOnly (Type{X} brings its kind    *)
(* alone: ValuesCovered), NoSupertype (SupertypeClosed), NoFields            *)
(* (FieldsClosed), KindsAlways (Type{X} brings every kind: NothingExtra),    *)
(* NoContents (a constant brings its own class alone: ValuesCovered, a Float *)
(* held in a field declared Any never numbered).                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    NoSeenGuard,  \* Broken: a class met again is walked again
    KindOnly,     \* Broken: Type{X} brings its kind alone, not the classes X denotes
    NoSupertype,  \* Broken: a class brings no supertype
    NoFields,     \* Broken: a concrete class brings no field types
    KindsAlways,  \* Broken: Type{X} with X known brings every kind
    NoContents    \* Broken: a constant brings its own class, not the values it holds

\* the universe of classes, Julia's answers
Classes == {"Any", "Number", "Int", "Float", "Node", "Nothing", "Pair", "Str", "TypeT",
            "DataType", "UnionKind", "Box"}
Kinds   == <<"DataType", "UnionKind">>
KindSet == {Kinds[i] : i \in 1..Len(Kinds)}
Supertype(t) == CASE t \in {"Int", "Float"}  -> "Number"
                  [] t \in KindSet            -> "TypeT"
                  [] OTHER                    -> "Any"
IsConcrete(t) == t \notin {"Any", "Number", "TypeT"}

\* value types: a DataType, a Union of DataTypes, a Vararg, Type{X} with X a DataType, a Union or
\* unknown (T), a UnionAll under Type, Union{}
DT(t)      == [k |-> "dt", t |-> t, s |-> <<>>]
U(s)       == [k |-> "union", t |-> "", s |-> s]
Va(t)      == [k |-> "vararg", t |-> t, s |-> <<>>]
TyDT(t)    == [k |-> "type", t |-> t, s |-> <<>>]
TyU(s)     == [k |-> "typeunion", t |-> "", s |-> s]
TyTV       == [k |-> "typetv", t |-> "", s |-> <<>>]
TyAll      == [k |-> "typeall", t |-> "", s |-> <<>>]
Bottom     == [k |-> "bottom", t |-> "", s |-> <<>>]

FieldTypes(t) == CASE t = "Node" -> <<U(<<"Node", "Nothing">>)>>
                   [] t = "Pair" -> <<DT("Int"), DT("Float")>>
                   [] t = "Box"  -> <<DT("Any")>>
                   [] OTHER      -> <<>>

\* constant objects, Julia's values: each its class and the objects it holds. A Box whose field,
\* declared Any, holds a Float; a Node whose next is itself (a cycle the object guard ends)
Objects == {"box", "f", "cyc"}
ClassOf(o) == CASE o = "box" -> "Box" [] o = "f" -> "Float" [] o = "cyc" -> "Node"
Contents(o) == CASE o = "box" -> <<"f">> [] o = "cyc" -> <<"cyc">> [] OTHER -> <<>>
Cst(o) == [k |-> "const", t |-> o, s |-> <<>>]
RECURSIVE Reach(_)
Reach(S) == LET N == S \cup UNION {{Contents(o)[i] : i \in 1..Len(Contents(o))} : o \in S}
            IN IF N = S THEN S ELSE Reach(N)
KindFields(k) == IF k = "DataType" THEN <<DT("Str")>> ELSE <<>>

Forms == {DT("Int"), DT("Pair"), DT("Node"), DT("Str"), U(<<"Int", "Nothing">>), Va("Float"),
          TyDT("Int"), TyU(<<"Int", "Float">>), TyTV, TyAll, Bottom, Cst("box"), Cst("cyc")}
Programs == {<<f>> : f \in Forms} \cup {<<f, g>> : f, g \in Forms}

Range(q) == {q[i] : i \in 1..Len(q)}

\* the classes a value of the type can have, and those a type value's layout names
ValueClassesOf(f) ==
    CASE f.k = "dt"        -> {f.t}
      [] f.k = "union"     -> Range(f.s)
      [] f.k = "vararg"    -> {f.t}
      [] f.k = "type"      -> {"DataType", f.t}
      [] f.k = "typeunion" -> {"UnionKind"} \cup Range(f.s)
      [] f.k = "typetv"    -> KindSet
      [] f.k = "typeall"   -> KindSet
      [] f.k = "bottom"    -> {}
      [] f.k = "const"     -> {ClassOf(o) : o \in Reach({f.t})}

FieldClasses(t) ==
    IF t \in KindSet THEN UNION {ValueClassesOf(f) : f \in Range(KindFields(t))}
    ELSE IF IsConcrete(t) THEN UNION {ValueClassesOf(f) : f \in Range(FieldTypes(t))}
    ELSE {}

RECURSIVE Closure(_)
Closure(S) == LET N == S \cup {Supertype(t) : t \in S} \cup UNION {FieldClasses(t) : t \in S}
              IN IF N = S THEN S ELSE Closure(N)

VARIABLES program, stack, out, seen, seenObj
vars == <<program, stack, out, seen, seenObj>>

Value(f) == [task |-> "value", f |-> f, t |-> ""]
Class(t) == [task |-> "class", f |-> Bottom, t |-> t]
Obj(o)   == [task |-> "object", f |-> Bottom, t |-> o]
Values(fs) == [i \in 1..Len(fs) |-> Value(fs[i])]
ClassesTasks(ts) == [i \in 1..Len(ts) |-> Class(ts[i])]

Required == Closure(UNION {ValueClassesOf(f) : f \in Range(program)})

TypeOK ==
    /\ program \in Programs
    /\ Range(out) \subseteq Classes
    /\ seen \subseteq Classes
    /\ seenObj \subseteq Objects

Init ==
    /\ program \in Programs
    /\ stack = Values(program)
    /\ out = <<>>
    /\ seen = {}
    /\ seenObj = {}

\* _meet_value!: what a value's type brings
MeetValue(f) ==
    CASE f.k = "dt"        -> <<Class(f.t)>>
      [] f.k = "union"     -> Values([i \in 1..Len(f.s) |-> DT(f.s[i])])
      [] f.k = "vararg"    -> <<Value(DT(f.t))>>
      [] f.k = "type"      -> IF KindsAlways THEN ClassesTasks(Kinds) \o <<Class(f.t)>>
                              ELSE IF KindOnly THEN <<Class("DataType")>>
                              ELSE <<Class("DataType"), Class(f.t)>>
      [] f.k = "typeunion" -> IF KindOnly THEN <<Class("UnionKind")>>
                              ELSE <<Class("UnionKind")>> \o ClassesTasks(f.s)
      [] f.k = "typetv"    -> ClassesTasks(Kinds)
      [] f.k = "typeall"   -> ClassesTasks(Kinds)
      [] f.k = "bottom"    -> <<>>
      [] f.k = "const"     -> <<Obj(f.t)>>

\* _meet_constant!: an object walked once, its class met, then each object it holds
MeetObject(o) ==
    <<Class(ClassOf(o))>> \o
    (IF NoContents THEN <<>> ELSE [i \in 1..Len(Contents(o)) |-> Obj(Contents(o)[i])])

\* _meet_class!: the class listed once, then its supertype, then its fields
MeetClass(t) ==
    (IF NoSupertype THEN <<>> ELSE <<Class(Supertype(t))>>) \o
    (IF t \in KindSet THEN Values(KindFields(t))
     ELSE IF IsConcrete(t) /\ ~NoFields THEN Values(FieldTypes(t))
     ELSE <<>>)

Step ==
    /\ stack # <<>>
    /\ LET x == Head(stack) IN
       IF x.task = "value"
       THEN /\ stack' = MeetValue(x.f) \o Tail(stack)
            /\ UNCHANGED <<program, out, seen, seenObj>>
       ELSE IF x.task = "object"
       THEN IF x.t \in seenObj
            THEN /\ stack' = Tail(stack)
                 /\ UNCHANGED <<program, out, seen, seenObj>>
            ELSE /\ seenObj' = seenObj \cup {x.t}
                 /\ stack' = MeetObject(x.t) \o Tail(stack)
                 /\ UNCHANGED <<program, out, seen>>
       ELSE IF x.t \in seen /\ ~NoSeenGuard
       THEN /\ stack' = Tail(stack)
            /\ UNCHANGED <<program, out, seen, seenObj>>
       ELSE /\ seen' = seen \cup {x.t}
            /\ out' = Append(out, x.t)
            /\ stack' = MeetClass(x.t) \o Tail(stack)
            /\ UNCHANGED <<program, seenObj>>

Done == stack = <<>>
Terminal == Done /\ UNCHANGED vars

Next == Step \/ Terminal
Spec == Init /\ [][Next]_vars /\ WF_vars(Step)

Once            == \A i, j \in 1..Len(out) : i # j => out[i] # out[j]
ValuesCovered   == Done => UNION {ValueClassesOf(f) : f \in Range(program)} \subseteq Range(out)
SupertypeClosed == Done => \A t \in Range(out) : t # "Any" => Supertype(t) \in Range(out)
FieldsClosed    == Done => \A t \in Range(out) : FieldClasses(t) \subseteq Range(out)
NothingExtra    == Range(out) \subseteq Required
Terminates      == <>Done
=============================================================================
