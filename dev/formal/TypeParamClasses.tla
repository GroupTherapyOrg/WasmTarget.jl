------------------------ MODULE TypeParamClasses ------------------------------
(***************************************************************************)
(* A TLA+ model of the pass closed_world_classes (src/julia/classes.jl) runs *)
(* after its walk: one loop over the class list as it grows, each class      *)
(* bringing                                                                  *)
(*   its record, when it is a concrete tuple class (the record rule, the     *)
(*     class its value has where convertType boxes it into an open slot);    *)
(*   where the program holds a type value (the walk met DataType, the kind), *)
(*     each of its parameters that is a type or a type variable, met as a    *)
(*     constant (_meet_constant!): a type's kind (DataType) and the type     *)
(*     itself, then each parameter it holds in turn (DataType's `parameters`,*)
(*     _kind_instance_fields), a type variable its class (TypeVar), each     *)
(*     object walked once; every class met by _meet_class!: listed once,     *)
(*     its supertype, and a concrete class's fields (a class with a free     *)
(*     type variable, `Type{T}` or a UnionAll's body, is not concrete, so    *)
(*     it brings its supertype alone).                                       *)
(* Why the trigger: every class's type value is made in one table, read by   *)
(* Julia's typeof (src/intrinsics.jl to_typeof) and by an as check's failure *)
(* (src/types.jl:607, src/julia/runtime/rtutils.jl jl_to_typeof), each      *)
(* reader's result a DataType; a type value's layout holds the class id of   *)
(* each class it denotes (dart's classIds[type.classNode]!, constants.dart:  *)
(* 430 _makeInterfaceTypeConstant), so each parameter's class is numbered.  *)
(* The walk before the pass is ValueClasses.tla's; here it is the closure of *)
(* the program's seed classes under supertype and fields, then the pass.    *)
(*                                                                           *)
(* ABSTRACTION. Classes are tokens with Julia's answers as fixed operators:  *)
(* Supertype, IsConcrete, a concrete class's field classes, a class's type  *)
(* parameters. A nested parameter reached only through a new class's         *)
(* supertype (_GeRgE{L,R} <: _GeRgF{_GeRgE{L,Any},R}, here B <: SB{Q}) is   *)
(* what makes the pass a fixpoint. A free class's would-be fields (Elt, a    *)
(* Memory body's element) exist only for the FreeFields variant. A program  *)
(* is one or two seed classes; DataType among them is a type value held.    *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   Once            no class is listed twice                                *)
(*   ParamsClosed    where a type value is held, every listed class's        *)
(*                   parameters' classes are listed, at any depth            *)
(*   RecordsClosed   every listed concrete tuple class's record is listed    *)
(*   NothingExtra    every listed class is required by the above             *)
(*   Terminates      the pass ends                                           *)
(* Broken variants: OneLevel (the pass reads only the classes listed when it *)
(* starts: ParamsClosed, SB's parameter Q never listed), NoHeldGate (the     *)
(* parameters met with no type value held: NothingExtra), FreeFields (a      *)
(* class with a free type variable given fields: NothingExtra).             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    OneLevel,    \* Broken: the pass reads the list as it was when the pass started
    NoHeldGate,  \* Broken: parameters are met where no type value is held
    FreeFields   \* Broken: a class with a free type variable brings fields

Classes == {"Any", "A", "B", "SB", "Q", "Str", "DataType", "TypeT", "TypeVar", "Svec",
            "Box2", "Tup", "Rec1", "Elt"}
\* the objects a parameter can be: a type (its own token) or a type variable
TV == "tv"
Objects == (Classes \ {"Rec1", "Elt"}) \cup {TV}

Supertype(t) == CASE t = "B"        -> "SB"
                  [] t = "DataType" -> "TypeT"
                  [] OTHER          -> "Any"
\* Type{T} (DataType's supertype) has a free type variable; Any and SB are abstract
IsConcrete(t) == t \notin {"Any", "SB", "TypeT"}
IsFree(t) == t = "TypeT"
\* A = _GeFq5A{B}, B = _GeFq5B{Str} <: SB{Q}; Box2{Tup} holding a Tup, Tup = Tuple{Str}; Type{T}'s T a type variable
Params(t) == CASE t = "A"     -> <<"B">>
               [] t = "B"     -> <<"Str">>
               [] t = "SB"    -> <<"Q">>
               [] t = "Box2"  -> <<"Tup">>
               [] t = "Tup"   -> <<"Str">>
               [] t = "TypeT" -> <<TV>>
               [] OTHER       -> <<>>
TupleClasses == {"Tup"}
RecordOf(t) == "Rec1"
\* a concrete class's fields' classes (DataType's `parameters` field, a SimpleVector); a free class's
\* would-be fields, which only FreeFields walks
FieldTypes(t) == CASE t = "DataType" -> <<"Svec">>
                   [] t = "Box2"     -> <<"Tup">>
                   [] t = "TypeT"    -> <<"Elt">>
                   [] OTHER          -> <<>>

SeedOrder == <<"A", "Box2", "DataType", "Str">>
Seeds == {SeedOrder[i] : i \in 1..Len(SeedOrder)}
Programs == {{s} : s \in Seeds} \cup {{s, u} : s, u \in Seeds}

Range(q) == {q[i] : i \in 1..Len(q)}
FieldsOf(t) == IF IsConcrete(t) THEN Range(FieldTypes(t)) ELSE {}
RecordsOf(t) == IF t \in TupleClasses THEN {RecordOf(t)} ELSE {}
\* an object's classes: a type's kind and the type, a type variable's TypeVar
ObjClasses(o) == IF o = TV THEN {"TypeVar"} ELSE {"DataType", o}
Contents(o) == IF o = TV THEN <<>> ELSE Params(o)
RECURSIVE Reach(_)
Reach(S) == LET N == S \cup UNION {Range(Contents(o)) : o \in S}
            IN IF N = S THEN S ELSE Reach(N)
ParamClasses(t) == UNION {ObjClasses(o) : o \in Reach(Range(Params(t)))}

RECURSIVE Closure0(_), Closure1(_)
Closure0(S) == LET N == S \cup {Supertype(t) : t \in S} \cup UNION {FieldsOf(t) \cup RecordsOf(t) : t \in S}
               IN IF N = S THEN S ELSE Closure0(N)
Closure1(S) == LET N == S \cup {Supertype(t) : t \in S}
                          \cup UNION {FieldsOf(t) \cup RecordsOf(t) \cup ParamClasses(t) : t \in S}
               IN IF N = S THEN S ELSE Closure1(N)

VARIABLES program, stack, out, seen, seenObj, phase, k, len0, held
vars == <<program, stack, out, seen, seenObj, phase, k, len0, held>>

Class(t) == [task |-> "class", t |-> t]
Obj(o)   == [task |-> "object", t |-> o]
SeqTasks(f(_), s) == [i \in 1..Len(s) |-> f(s[i])]

\* the facts the claims judge, from the program: whether the walk met DataType, and what is required
Held == "DataType" \in Closure0(program)
Required == IF Held THEN Closure1(program) ELSE Closure0(program)

TypeOK ==
    /\ program \in Programs
    /\ Range(out) \subseteq Classes
    /\ seen \subseteq Classes
    /\ seenObj \subseteq Objects
    /\ phase \in {"walk", "pass", "done"}
    /\ k \in Nat /\ len0 \in Nat /\ held \in BOOLEAN

Init ==
    /\ program \in Programs
    /\ stack = SeqTasks(Class, SelectSeq(SeedOrder, LAMBDA s : s \in program))
    /\ out = <<>>
    /\ seen = {}
    /\ seenObj = {}
    /\ phase = "walk"
    /\ k = 0 /\ len0 = 0 /\ held = FALSE

\* _meet_class!: listed once, then its supertype, then a concrete class's fields
MeetClass(t) ==
    <<Class(Supertype(t))>> \o
    (IF IsConcrete(t) \/ (FreeFields /\ IsFree(t)) THEN SeqTasks(Class, FieldTypes(t)) ELSE <<>>)

\* _meet_constant! of a parameter: its classes (a type's kind and itself, a type variable's TypeVar), then
\* each parameter it holds
MeetObject(o) ==
    (IF o = TV THEN <<Class("TypeVar")>> ELSE <<Class("DataType"), Class(o)>>) \o SeqTasks(Obj, Contents(o))

Step ==
    /\ stack # <<>>
    /\ LET x == Head(stack) IN
       IF x.task = "object"
       THEN IF x.t \in seenObj
            THEN /\ stack' = Tail(stack)
                 /\ UNCHANGED <<program, out, seen, seenObj, phase, k, len0, held>>
            ELSE /\ seenObj' = seenObj \cup {x.t}
                 /\ stack' = MeetObject(x.t) \o Tail(stack)
                 /\ UNCHANGED <<program, out, seen, phase, k, len0, held>>
       ELSE IF x.t \in seen
       THEN /\ stack' = Tail(stack)
            /\ UNCHANGED <<program, out, seen, seenObj, phase, k, len0, held>>
       ELSE /\ seen' = seen \cup {x.t}
            /\ out' = Append(out, x.t)
            /\ stack' = MeetClass(x.t) \o Tail(stack)
            /\ UNCHANGED <<program, seenObj, phase, k, len0, held>>

\* the walk's end: the pass starts, reading whether the walk met DataType
StartPass ==
    /\ stack = <<>>
    /\ phase = "walk"
    /\ phase' = "pass"
    /\ held' = ("DataType" \in seen)
    /\ len0' = Len(out)
    /\ UNCHANGED <<program, stack, out, seen, seenObj, k>>

Bound == IF OneLevel THEN len0 ELSE Len(out)

\* one class of the pass: its parameters where a type value is held, then its record
PassStep ==
    /\ stack = <<>>
    /\ phase = "pass"
    /\ k < Bound
    /\ LET c == out[k + 1] IN
       stack' = (IF held \/ NoHeldGate THEN SeqTasks(Obj, Params(c)) ELSE <<>>) \o
                (IF c \in TupleClasses THEN <<Class(RecordOf(c))>> ELSE <<>>)
    /\ k' = k + 1
    /\ UNCHANGED <<program, out, seen, seenObj, phase, len0, held>>

Finish ==
    /\ stack = <<>>
    /\ phase = "pass"
    /\ k >= Bound
    /\ phase' = "done"
    /\ UNCHANGED <<program, stack, out, seen, seenObj, k, len0, held>>

Done == phase = "done"
Terminal == Done /\ UNCHANGED vars

Next == Step \/ StartPass \/ PassStep \/ Finish \/ Terminal
Spec == Init /\ [][Next]_vars /\ WF_vars(Step \/ StartPass \/ PassStep \/ Finish)

Once          == \A i, j \in 1..Len(out) : i # j => out[i] # out[j]
ParamsClosed  == Done /\ Held => \A t \in Range(out) : ParamClasses(t) \subseteq Range(out)
RecordsClosed == Done => \A t \in Range(out) : RecordsOf(t) \subseteq Range(out)
NothingExtra  == Range(out) \subseteq Required
Terminates    == <>Done
=============================================================================
