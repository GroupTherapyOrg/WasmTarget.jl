---------------------------- MODULE TupleRecord ------------------------------
(***************************************************************************)
(* formal(dev/formal/TupleRecord.tla): the tuple record model's arms        *)
(* (src/julia/classes.jl TupleRecord): convertType's box and unbox of a      *)
(* tuple (src/translator.jl convert_type, the arms ahead of its subtype      *)
(* test), and the producers of a tuple in a slot: a tuple of a concrete      *)
(* static type built as its own class (visit_record_literal), an open tuple  *)
(* built as the record of its arity (src/intrinsics.jl's open_tuple arm, for *)
(* a literal and an open-count varargs call alike), and a tuple constant     *)
(* (src/constants.jl instantiate, its record inline where the expected slot  *)
(* is not its own class).                                                    *)
(*                                                                           *)
(* The invariant every reader rests on: a slot whose static type is open (a  *)
(* top-typed slot) never holds a concrete tuple's struct. The is checker     *)
(* (src/types.jl, _RecordType._checkInstance), the run-time index and        *)
(* nfields read only records there; a concrete struct in a top slot would    *)
(* validate (every class is below the top struct) and answer isa false where *)
(* Julia answers true.                                                       *)
(*                                                                           *)
(* ABSTRACTION. One concrete tuple class Tc of arity n and its record Rn; a  *)
(* value is its contents (two tuples, A and B) or Julia's `nothing`, held as *)
(* the null of a nullable slot. A slot is typed concrete (Tc), nullable      *)
(* concrete (Union{Nothing,Tc}), or top. A step produces a value into a slot *)
(* or moves a slot's value into another slot through convertType; each slot  *)
(* records the Julia value it holds beside its representation.               *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   TopHoldsNoConcrete  no top slot holds Tc's struct                       *)
(*   IsaAgrees           the record is-check of a top slot's value answers   *)
(*                       Julia's isa (a tuple is a Tc; nothing is not)       *)
(*   ValueKept           every slot's representation holds its Julia value:  *)
(*                       the null exactly where it is `nothing`, else the    *)
(*                       tuple's contents, in Tc or Rn                       *)
(* Broken variants: ProducerSkipsBox (a producer leaves Tc in a top slot,    *)
(* the constant's arm without its record: TopHoldsNoConcrete), BoxNull (the  *)
(* box makes a record of a nullable slot's null, `nothing` then answering   *)
(* isa true: IsaAgrees).                                                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    ProducerSkipsBox,   \* Broken: a tuple constant bound for a top slot is instantiated as Tc
    BoxNull             \* Broken: the box of a nullable concrete slot's null builds a record

Tuples    == {"A", "B"}
Values    == Tuples \cup {"nothing"}
SlotTypes == {"concrete", "nullable", "top"}
Slots     == 1..3
\* each slot's static type, every assignment of the three types to the slots
SlotTyping == [Slots -> SlotTypes]

Null       == [cls |-> "null", c |-> "nothing"]
Struct(c)  == [cls |-> "Tc", c |-> c]
Record(c)  == [cls |-> "Rn", c |-> c]
Empty      == [cls |-> "empty", c |-> "nothing"]
Reps       == {Null, Empty} \cup {Struct(c) : c \in Tuples} \cup {Record(c) : c \in Values}

\* the values a slot of the type admits
Admits(ty, v) == CASE ty = "concrete" -> v \in Tuples
                   [] ty = "nullable" -> TRUE
                   [] ty = "top"      -> TRUE

\* convertType from a slot's representation to another slot's type
\*   concrete or nullable -> top: the box (a Tc's fields into its record), the null kept
\*   top -> concrete or nullable: the unbox (the record's fields into a Tc), the null kept
\*   any other pair: the value as it is (the same representation)
Convert(r, from, to) ==
    IF from # "top" /\ to = "top"
    THEN IF r = Null THEN (IF BoxNull THEN Record("nothing") ELSE Null) ELSE Record(r.c)
    ELSE IF from = "top" /\ to # "top"
    THEN IF r = Null THEN Null ELSE Struct(r.c)
    ELSE r

\* the producers, each the representation it writes into a slot of the type
\*   literal:     a tuple of a concrete static type, its own class, converted into the slot
\*   openTuple:   an open literal or an open-count varargs call, the record (open_tuple arm),
\*                into a top slot only (its static type is open)
\*   constant:    instantiate, the record inline where the slot is not Tc's own
\*   nothing:     Julia's nothing, the null, into a slot that admits it
Produce(p, v, ty) ==
    CASE p = "literal"   -> Convert(Struct(v), "concrete", ty)
      [] p = "openTuple" -> Record(v)
      [] p = "constant"  -> IF ty = "top" /\ ~ProducerSkipsBox THEN Record(v) ELSE Struct(v)
      [] p = "nothing"   -> Null

Producers == {"literal", "openTuple", "constant", "nothing"}
CanProduce(p, v, ty) ==
    /\ Admits(ty, v)
    /\ (p = "nothing") <=> (v = "nothing")
    /\ p = "openTuple" => ty = "top"

VARIABLES typing, rep, jv
vars == <<typing, rep, jv>>

TypeOK ==
    /\ typing \in SlotTyping
    /\ rep \in [Slots -> Reps]
    /\ jv \in [Slots -> Values]

Init ==
    /\ typing \in SlotTyping
    /\ rep = [s \in Slots |-> Empty]
    /\ jv = [s \in Slots |-> "nothing"]

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

TopHoldsNoConcrete == \A s \in Slots : typing[s] = "top" /\ Held(s) => rep[s].cls # "Tc"
\* the record is-check: a top slot's value is a Tc exactly when it is a record (records only)
IsaAgrees == \A s \in Slots : typing[s] = "top" /\ Held(s) =>
                 ((rep[s].cls = "Rn") <=> (jv[s] \in Tuples))
ValueKept == \A s \in Slots : Held(s) =>
                 /\ (rep[s] = Null) <=> (jv[s] = "nothing")
                 /\ rep[s] # Null => rep[s].c = jv[s]
=============================================================================
