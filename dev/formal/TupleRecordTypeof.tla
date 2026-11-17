------------------------- MODULE TupleRecordTypeof ----------------------------
(***************************************************************************)
(* formal(dev/formal/TupleRecordTypeof.tla): typeof of a tuple record       *)
(* (src/intrinsics.jl to_typeof, src/julia/classes.jl record_typeof), over   *)
(* the tuple record model with the splat (src/julia/classes.jl TupleRecord,  *)
(* TupleRecordArray).                                                        *)
(*                                                                           *)
(* STANDS BESIDE TupleRecordSplat.tla and TupleRecord.tla, which stay as     *)
(* they are. It restates TupleRecordSplat.tla's slots, producers, convertType *)
(* and its claims TopHoldsNoConcrete, IsaAgrees, ValueKept,                  *)
(* OneRepresentation, EgalAgrees and NarrowNeverArray over a larger state: a *)
(* top slot of a third kind, mixed, and a value of no tuple type. Its        *)
(* TypeofAgrees replaces that model's, which assumed the pinned rule instead *)
(* of checking it and had no gap a catch could observe.                      *)
(*                                                                           *)
(* THE SPLAT. A tuple whose length only run time knows,                      *)
(* `Core._apply_iterate(iterate, Core.tuple, v)` (julia/src/builtins.c:661   *)
(* jl_f__apply_iterate, then :946 jl_f_tuple), is a fifth producer, into a   *)
(* top slot only (its static type is Tuple{Vararg{E}}). Julia finds the      *)
(* tuple's type in its cache and makes one only on a miss (jltypes.c:1133    *)
(* lookup_typevalue); the port takes the record of the run-time arity where  *)
(* the closed world has it (a hit: Rn) and otherwise the one array class, Ra *)
(* (TupleRecordArray), whose one field is the argument buffer. A tuple has   *)
(* an arity, covered (Tc's, whose record the closed world has: every         *)
(* concrete tuple class brings its arity's record) or uncovered (no record,  *)
(* so no concrete class either); only the splat makes an uncovered tuple.    *)
(* `nothing` is a value of a tuple's shape, so TLC compares any two values.  *)
(* The is-check tests Tc, a fixed open type of each arity (NTuple{n,Any},   *)
(* NTuple{u,Any}) and the Vararg type, over the classes open_tuple_holds     *)
(* admits: Rn where the type admits the covered arity, Ra where it admits an *)
(* uncovered one, Ra's arm testing its run-time length.                      *)
(*                                                                           *)
(* TYPEOF. Julia's typeof of a tuple is the tuple type of its elements'      *)
(* types, found in its type cache or made (jl_f_tuple). A top slot is open   *)
(* (Any), pinned (its static type holds one tuple type of each arity:       *)
(* typeintersect with NTuple{n,Any} concrete) or mixed (a Union of one       *)
(* concrete tuple type and a non-tuple, whose classes list that tuple's     *)
(* class, never its record, though a tuple held there is boxed into it).    *)
(* to_typeof gives every record the value can be an arm: the records among  *)
(* the operand's classes and each concrete tuple class's box record. A fixed *)
(* arity's arm answers record_typeof, the one tuple type the slot's type     *)
(* holds at that arity, computed from the type; the array class's arity only *)
(* run time knows, so its arm never answers, pinned or not. An arm that      *)
(* answers no type is the deferred gap, fatal: the located message goes to   *)
(* the host and the module traps, so no catch of the program observes it     *)
(* (audit A68S3: no DataType is made at run time).                           *)
(*                                                                           *)
(* The producers and convertType, as in TupleRecord.tla: a tuple of a        *)
(* concrete static type is its own class (visit_record_literal), boxed into  *)
(* its arity's record where it flows into a top slot and unboxed where Julia *)
(* narrows it; an open tuple is the record of its arity (the open_tuple arm);*)
(* a tuple constant is its record inline in a top slot.                      *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   TopHoldsNoConcrete  no top slot holds Tc's struct (TupleRecord.tla's)   *)
(*   IsaAgrees           the record is-check answers Julia's isa for every   *)
(*                       tested type (TupleRecord.tla's, at Tc)              *)
(*   ValueKept           every slot's representation holds its Julia value   *)
(*                       (TupleRecord.tla's)                                 *)
(*   OneRepresentation   a top slot's tuple is Rn iff its arity is covered,  *)
(*                       else Ra: the arity alone picks the class            *)
(*   EgalAgrees          === of any two slots' values, each converted to the *)
(*                       top, is the class-and-contents compare              *)
(*   NarrowNeverArray    no concrete or nullable slot holds Ra               *)
(*   TypeofAgrees        typeof of a top slot's value, as the program sees   *)
(*                       it, is Julia's or the fatal gap, never another      *)
(*                       value (a null table entry, a handler's value)       *)
(*   PinnedAnswers       a record of a fixed arity whose slot's type holds   *)
(*                       one tuple type at it answers exactly the value's    *)
(*                       own type (record_typeof, checked, not assumed)      *)
(* Broken variants (each cfg's expect line), each refuted by TypeofAgrees:  *)
(* TypeofAnswersRecord (typeof answers the record class), ArmsOmitBoxRecord  *)
(* (the arms are the operand's records alone, the mixed slot's box record    *)
(* left out, its null entry read), FatalIsException (the gap an exception a  *)
(* catch observes). ProducerSkipsBox, BoxNull, SplatAlwaysArray and          *)
(* HoldsOmitsArray are kept false here: TupleRecord.tla's and                *)
(* TupleRecordSplat.tla's own Broken cfgs refute them.                       *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    ProducerSkipsBox,   \* Broken: a tuple constant bound for a top slot is instantiated as Tc
    BoxNull,            \* Broken: the box of a nullable concrete slot's null builds a record
    SplatAlwaysArray,   \* Broken: the splat builds Ra whatever its run-time arity
    HoldsOmitsArray,    \* Broken: open_tuple_holds leaves Ra out of a fixed open type of an uncovered arity
    TypeofAnswersRecord,\* Broken: typeof of a tuple held as its record answers the record class
    ArmsOmitBoxRecord,  \* Broken: typeof's arms are the records among the operand's classes alone, so a tuple
                        \* boxed into its record from a concrete class the operand lists reads the table
    FatalIsException    \* Broken: the deferred gap is an exception the program's own catch observes

Arities   == {"cov", "unc"}          \* Tc's arity, whose record the closed world has; an arity it has none of
Covered(a) == a = "cov"
Contents  == {"A", "B"}
Tuples    == [ar : Arities, c : Contents]
CovTuples == {t \in Tuples : Covered(t.ar)}
\* Julia's `nothing`, a value of the same shape as a tuple's so TLC compares any two values
NothingV  == [ar |-> "none", c |-> "none"]
\* a value of no tuple type (an Int64 beside a tuple in a Union), of the same shape
OtherV    == [ar |-> "other", c |-> "other"]
Values    == Tuples \cup {NothingV, OtherV}
\* "pinned": a top slot whose static type holds one tuple type of each arity (Union{Tuple{Int64},
\* Tuple{Int64,Float64}}: typeintersect with NTuple{n,Any} concrete), its tuples here of contents "A" alone
\* "mixed": a top slot whose static type is a Union of one concrete tuple type and a non-tuple
\* (Union{Int64,Tuple{Int64}}): its classes are Tc and the other's, never a record, yet a tuple there is
\* boxed into its arity's record, the class typeof meets at run time
SlotTypes == {"concrete", "nullable", "top", "pinned", "mixed"}
IsTop(ty) == ty \in {"top", "pinned", "mixed"}
Slots     == 1..3
\* each slot's static type, every assignment of the three types to the slots
SlotTyping == [Slots -> SlotTypes]

Null       == [cls |-> "null", c |-> NothingV]
Struct(v)  == [cls |-> "Tc", c |-> v]
Record(v)  == [cls |-> "Rn", c |-> v]
Arr(v)     == [cls |-> "Ra", c |-> v]
Empty      == [cls |-> "empty", c |-> NothingV]
OtherRep   == [cls |-> "Other", c |-> OtherV]
Reps       == {Null, Empty, OtherRep} \cup {Struct(v) : v \in CovTuples} \cup {Record(v) : v \in CovTuples \cup {NothingV}}
                  \cup {Arr(v) : v \in Tuples}

\* the values a slot of the type admits: a concrete tuple slot holds Tc's arity alone
Admits(ty, v) == CASE ty = "concrete" -> v \in CovTuples
                   [] ty = "nullable" -> v \in CovTuples \cup {NothingV}
                   [] ty = "top"      -> TRUE
                   [] ty = "pinned"   -> v = NothingV \/ (v \in Tuples /\ v.c = "A")
                   [] ty = "mixed"    -> v = OtherV \/ (v \in CovTuples /\ v.c = "A")

\* convertType from a slot's representation to another slot's type
\*   concrete or nullable -> top: the box (a Tc's fields into its record), the null kept
\*   top -> concrete or nullable: the unbox (a ref.cast to Tc's record, its fields into a Tc), the
\*     null kept; the cast of an Ra fails, which leaves Ra (NarrowNeverArray says it never happens)
\*   any other pair: the value as it is (the same representation)
Convert(r, from, to) ==
    IF ~IsTop(from) /\ IsTop(to)
    THEN IF r = Null THEN (IF BoxNull THEN Record(NothingV) ELSE Null) ELSE Record(r.c)
    ELSE IF IsTop(from) /\ ~IsTop(to)
    THEN IF r = Null THEN Null ELSE IF r.cls = "Ra" THEN r ELSE Struct(r.c)
    ELSE r

\* the splat (the producer of src/intrinsics.jl's _apply_iterate arm): Julia's type-cache lookup,
\* the record of the run-time arity where the closed world has it, else the array class
Splat(v) == IF Covered(v.ar) /\ ~SplatAlwaysArray THEN Record(v) ELSE Arr(v)

\* the producers, each the representation it writes into a slot of the type
\*   literal:     a tuple of a concrete static type, its own class, converted into the slot
\*   openTuple:   an open literal or an open-count varargs call, the record (open_tuple arm),
\*                into a top slot only (its static type is open)
\*   constant:    instantiate, the record inline where the slot is not Tc's own
\*   nothing:     Julia's nothing, the null, into a slot that admits it
\*   splat:       a tuple of run-time arity, into a top slot only
\*   other:       a value of no tuple type, its own class, into a top slot
Produce(p, v, ty) ==
    CASE p = "literal"   -> Convert(Struct(v), "concrete", ty)
      [] p = "openTuple" -> Record(v)
      [] p = "constant"  -> IF IsTop(ty) /\ ~ProducerSkipsBox THEN Record(v) ELSE Struct(v)
      [] p = "nothing"   -> Null
      [] p = "splat"     -> Splat(v)
      [] p = "other"     -> OtherRep

Producers == {"literal", "openTuple", "constant", "nothing", "splat", "other"}
CanProduce(p, v, ty) ==
    /\ Admits(ty, v)
    /\ (p = "nothing") <=> (v = NothingV)
    /\ (p = "other") <=> (v = OtherV)
    /\ p \in {"openTuple", "splat", "other"} => IsTop(ty)
    /\ p = "splat" => v \in Tuples
    \* every producer but the splat builds a tuple of an arity it states, whose record the closed
    \* world has (src/julia/classes.jl: each concrete tuple class and each open_tuple brings it)
    /\ p \in {"literal", "openTuple", "constant"} => v \in CovTuples

\* the open tuple types an is-check tests: Tc, NTuple{n,Any}, NTuple{u,Any} (u uncovered), Tuple{Vararg}
TestTypes == {"Tc", "fixedCov", "fixedUnc", "vararg"}
JuliaIsa(v, T) == v \in Tuples /\
    CASE T = "Tc"       -> Covered(v.ar)
      [] T = "fixedCov" -> Covered(v.ar)
      [] T = "fixedUnc" -> ~Covered(v.ar)
      [] T = "vararg"   -> TRUE
\* the classes the type's class-id switch admits (open_tuple_holds): a record where the type admits its
\* arity, Ra where the type admits an arity no record covers
Holds(T) ==
    CASE T = "Tc"       -> {"Rn"}
      [] T = "fixedCov" -> {"Rn"}
      [] T = "fixedUnc" -> IF HoldsOmitsArray THEN {} ELSE {"Ra"}
      [] T = "vararg"   -> {"Rn", "Ra"}
\* the record is-check over a top slot: the class-id switch, then Ra's arm its run-time length test
IsaCheck(r, T) == r.cls \in Holds(T) /\ (r.cls = "Ra" => JuliaIsa(r.c, T))

VARIABLES typing, rep, jv
vars == <<typing, rep, jv>>

TypeOK ==
    /\ typing \in SlotTyping
    /\ rep \in [Slots -> Reps]
    /\ jv \in [Slots -> Values]

Init ==
    /\ typing \in SlotTyping
    /\ rep = [s \in Slots |-> Empty]
    /\ jv = [s \in Slots |-> NothingV]

ProduceStep ==
    \E s \in Slots, p \in Producers, v \in Values :
        /\ rep[s] = Empty
        /\ CanProduce(p, v, typing[s])
        /\ rep' = [rep EXCEPT ![s] = Produce(p, v, typing[s])]
        /\ jv' = [jv EXCEPT ![s] = v]
        /\ UNCHANGED typing

\* a value moved into another slot that admits it (Julia's PiNode or typeassert narrows a top
\* slot's tuple into a concrete one; a call passes a concrete tuple to an open parameter)
MoveStep ==
    \E s, d \in Slots :
        /\ s # d
        /\ rep[s] # Empty
        /\ rep[d] = Empty
        /\ Admits(typing[d], jv[s])
        /\ rep' = [rep EXCEPT ![d] = Convert(rep[s], typing[s], typing[d])]
        /\ jv' = [jv EXCEPT ![d] = jv[s]]
        /\ UNCHANGED typing

Full == \A s \in Slots : rep[s] # Empty
Next == ProduceStep \/ MoveStep \/ (Full /\ UNCHANGED vars)
Spec == Init /\ [][Next]_vars

Held(s) == rep[s] # Empty
\* a slot's value as === sees it: converted to the top (egal boxes both operands)
AtTop(s) == Convert(rep[s], typing[s], "top")

TopHoldsNoConcrete == \A s \in Slots : IsTop(typing[s]) /\ Held(s) => rep[s].cls # "Tc"
\* the record is-check: a top slot's value passes the check of each tested type exactly where
\* Julia's isa does (for Tc: it is a record exactly when it is a tuple of Tc's arity)
IsaAgrees == \A s \in Slots : IsTop(typing[s]) /\ Held(s) =>
                 \A T \in TestTypes : IsaCheck(rep[s], T) <=> JuliaIsa(jv[s], T)
ValueKept == \A s \in Slots : Held(s) =>
                 /\ (rep[s] = Null) <=> (jv[s] = NothingV)
                 /\ rep[s] # Null => rep[s].c = jv[s]
OneRepresentation == \A s \in Slots : IsTop(typing[s]) /\ Held(s) /\ jv[s] \in Tuples =>
                 rep[s].cls = (IF Covered(jv[s].ar) THEN "Rn" ELSE "Ra")
EgalAgrees == \A s, t \in Slots : Held(s) /\ Held(t) =>
                 ((AtTop(s).cls = AtTop(t).cls /\ AtTop(s).c = AtTop(t).c) <=> (jv[s] = jv[t]))
NarrowNeverArray == \A s \in Slots : ~IsTop(typing[s]) /\ Held(s) => rep[s].cls # "Ra"

\* typeof of a top slot's value (src/intrinsics.jl to_typeof). Julia's answer is the value's type, the tuple
\* type of its elements' types (julia/src/builtins.c:946 jl_f_tuple), abstracted as the value itself (its
\* arity and the contents its elements' types name), NothingV's for `nothing`, OtherV's for the other. The
\* port gives every record the operand's value can be an arm ahead of the table, whose entry for a record is
\* null: the records among the operand's classes and the record each concrete tuple class among them is
\* boxed into (ArmsOmitBoxRecord leaves the second out). An arm of a fixed arity answers the one tuple type
\* the slot's static type holds at that arity, computed from the type (record_typeof), where it holds one;
\* the array class's arity only run time knows, so its arm never answers (RunTimeArity => nothing); an arm
\* that answers no type is the deferred gap, FATAL: the located message goes to the host and the module
\* traps, so no catch of the program observes it (FatalIsException makes it an exception a handler turns
\* into its own value). No DataType is made at run time (audit A68S3)
None     == [ar |-> "none", c |-> "notype"]
Fatal    == [ar |-> "fatal", c |-> "fatal"]
Handled  == [ar |-> "handled", c |-> "handled"]
NullTrap == [ar |-> "nulltrap", c |-> "nulltrap"]
\* record_typeof: the one tuple type of arity `a` the static type `ty` admits, where it admits one
RecordTypeof(ty, a) ==
    LET S == {v \in Tuples : Admits(ty, v) /\ v.ar = a}
    IN IF Cardinality(S) = 1 THEN CHOOSE v \in S : TRUE ELSE None
\* the record classes with an arm in to_typeof for an operand of the static type `ty`
Arms(ty) == IF ArmsOmitBoxRecord /\ ty = "mixed" THEN {} ELSE {"Rn", "Ra"}
TypeofAnswer(s) ==
    IF rep[s] = Null THEN NothingV
    ELSE IF rep[s] = OtherRep THEN OtherV
    ELSE IF TypeofAnswersRecord THEN [ar |-> rep[s].cls, c |-> "record"]
    ELSE IF rep[s].cls \notin Arms(typing[s]) THEN NullTrap
    ELSE IF rep[s].cls = "Ra" THEN Fatal
    ELSE IF RecordTypeof(typing[s], rep[s].c.ar) = None THEN Fatal
    ELSE RecordTypeof(typing[s], rep[s].c.ar)
\* what the program sees: the fatal gap ends it, unless it is an exception a handler catches
Observed(s) == IF TypeofAnswer(s) = Fatal /\ FatalIsException THEN Handled ELSE TypeofAnswer(s)
\* correct or fatal: typeof is Julia's answer or the gap that ends the program, never another value
TypeofAgrees == \A s \in Slots : IsTop(typing[s]) /\ Held(s) => Observed(s) \in {jv[s], Fatal}
\* the pinned rule checked: a record of a fixed arity whose slot's type holds one tuple type at that arity
\* answers exactly the value's own type
PinnedAnswers == \A s \in Slots : IsTop(typing[s]) /\ Held(s) /\ rep[s].cls = "Rn" /\
                    RecordTypeof(typing[s], rep[s].c.ar) # None => TypeofAnswer(s) = jv[s]
=============================================================================
