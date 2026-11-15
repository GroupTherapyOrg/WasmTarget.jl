------------------------- MODULE TupleRecordSplat ----------------------------
(***************************************************************************)
(* formal(dev/formal/TupleRecordSplat.tla): a tuple of run-time arity and   *)
(* typeof of a tuple record, beside TupleRecord.tla (src/julia/classes.jl   *)
(* TupleRecord, TupleRecordArray; src/intrinsics.jl to_typeof).              *)
(*                                                                           *)
(* STANDS BESIDE TupleRecord.tla, which stays as it is. This model restates *)
(* its slots, producers, convertType and its claims TopHoldsNoConcrete,      *)
(* IsaAgrees and ValueKept with an arity on each tuple, so those claims are  *)
(* checked again here over the larger state; IsaAgrees is stated over every  *)
(* tested type, and at Tc it is TupleRecord.tla's claim.                     *)
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
(* or pinned: a pinned slot's static type holds one tuple type of each arity *)
(* (typeintersect with NTuple{n,Any} concrete), so typeof of its record is   *)
(* that type, known at compile time; in an open slot it would be a type made *)
(* at run time, which the port never makes (audit A68S3): it raises, named   *)
(* and located at the statement.                                             *)
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
(*   TypeofAgrees        typeof of a top slot's value is Julia's, or in an   *)
(*                       open slot the raise; never another type             *)
(* Broken variants (each cfg's expect line): SplatAlwaysArray (the splat     *)
(* always builds Ra, two representations of one value: OneRepresentation,    *)
(* and in its Egal cfg EgalAgrees), HoldsOmitsArray (open_tuple_holds leaves *)
(* Ra out of an uncovered fixed arity: IsaAgrees), TypeofAnswersRecord      *)
(* (typeof answers the record class: TypeofAgrees). ProducerSkipsBox and     *)
(* BoxNull are TupleRecord.tla's variants, kept false here: its own Broken   *)
(* cfgs refute them.                                                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    ProducerSkipsBox,   \* Broken: a tuple constant bound for a top slot is instantiated as Tc
    BoxNull,            \* Broken: the box of a nullable concrete slot's null builds a record
    SplatAlwaysArray,   \* Broken: the splat builds Ra whatever its run-time arity
    HoldsOmitsArray,    \* Broken: open_tuple_holds leaves Ra out of a fixed open type of an uncovered arity
    TypeofAnswersRecord \* Broken: typeof of a tuple held as its record answers the record class

Arities   == {"cov", "unc"}          \* Tc's arity, whose record the closed world has; an arity it has none of
Covered(a) == a = "cov"
Contents  == {"A", "B"}
Tuples    == [ar : Arities, c : Contents]
CovTuples == {t \in Tuples : Covered(t.ar)}
\* Julia's `nothing`, a value of the same shape as a tuple's so TLC compares any two values
NothingV  == [ar |-> "none", c |-> "none"]
Values    == Tuples \cup {NothingV}
\* "pinned": a top slot whose static type holds one tuple type of each arity (Union{Tuple{Int64},
\* Tuple{Int64,Float64}}: typeintersect with NTuple{n,Any} concrete), its tuples here of contents "A" alone
SlotTypes == {"concrete", "nullable", "top", "pinned"}
IsTop(ty) == ty \in {"top", "pinned"}
Slots     == 1..3
\* each slot's static type, every assignment of the three types to the slots
SlotTyping == [Slots -> SlotTypes]

Null       == [cls |-> "null", c |-> NothingV]
Struct(v)  == [cls |-> "Tc", c |-> v]
Record(v)  == [cls |-> "Rn", c |-> v]
Arr(v)     == [cls |-> "Ra", c |-> v]
Empty      == [cls |-> "empty", c |-> NothingV]
Reps       == {Null, Empty} \cup {Struct(v) : v \in CovTuples} \cup {Record(v) : v \in CovTuples \cup {NothingV}}
                  \cup {Arr(v) : v \in Tuples}

\* the values a slot of the type admits: a concrete tuple slot holds Tc's arity alone
Admits(ty, v) == CASE ty = "concrete" -> v \in CovTuples
                   [] ty = "nullable" -> v \in CovTuples \cup {NothingV}
                   [] ty = "top"      -> TRUE
                   [] ty = "pinned"   -> v = NothingV \/ v.c = "A"

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
Produce(p, v, ty) ==
    CASE p = "literal"   -> Convert(Struct(v), "concrete", ty)
      [] p = "openTuple" -> Record(v)
      [] p = "constant"  -> IF IsTop(ty) /\ ~ProducerSkipsBox THEN Record(v) ELSE Struct(v)
      [] p = "nothing"   -> Null
      [] p = "splat"     -> Splat(v)

Producers == {"literal", "openTuple", "constant", "nothing", "splat"}
CanProduce(p, v, ty) ==
    /\ Admits(ty, v)
    /\ (p = "nothing") <=> (v = NothingV)
    /\ p \in {"openTuple", "splat"} => IsTop(ty)
    \* every producer but the splat builds a tuple of an arity it states, whose record the closed
    \* world has (src/julia/classes.jl: each concrete tuple class and each open_tuple brings it)
    /\ p \in {"literal", "openTuple", "constant"} => v \in CovTuples

\* the open tuple types an is-check tests: Tc, NTuple{n,Any}, NTuple{u,Any} (u uncovered), Tuple{Vararg}
TestTypes == {"Tc", "fixedCov", "fixedUnc", "vararg"}
JuliaIsa(v, T) == v # NothingV /\
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
OneRepresentation == \A s \in Slots : IsTop(typing[s]) /\ Held(s) /\ jv[s] # NothingV =>
                 rep[s].cls = (IF Covered(jv[s].ar) THEN "Rn" ELSE "Ra")
EgalAgrees == \A s, t \in Slots : Held(s) /\ Held(t) =>
                 ((AtTop(s).cls = AtTop(t).cls /\ AtTop(s).c = AtTop(t).c) <=> (jv[s] = jv[t]))
NarrowNeverArray == \A s \in Slots : ~IsTop(typing[s]) /\ Held(s) => rep[s].cls # "Ra"

\* typeof of a top slot's value (src/intrinsics.jl to_typeof). Julia's answer is the value's type, the tuple
\* type of its elements' types (julia/src/builtins.c:946 jl_f_tuple), abstracted as the value itself (its
\* arity and the contents its elements' types name), NothingV's for `nothing`. The port answers a record
\* where the slot's static type pins its arity's one tuple type (a pinned slot: contents "A"), and raises,
\* named and located, where it would have to make that type at run time (an open top slot): no DataType
\* is made at run time (audit A68S3)
Raise == [ar |-> "raise", c |-> "raise"]
TypeofAnswer(s) ==
    IF rep[s] = Null THEN NothingV
    ELSE IF TypeofAnswersRecord THEN [ar |-> rep[s].cls, c |-> "record"]
    ELSE IF typing[s] = "pinned" THEN [ar |-> rep[s].c.ar, c |-> "A"]
    ELSE Raise
\* correct or loud: a pinned slot's typeof is Julia's, an open slot's Julia's or the raise, never another type
TypeofAgrees == \A s \in Slots : IsTop(typing[s]) /\ Held(s) =>
                 (TypeofAnswer(s) = jv[s] \/ (typing[s] = "top" /\ TypeofAnswer(s) = Raise))
=============================================================================
