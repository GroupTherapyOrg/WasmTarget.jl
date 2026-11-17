-------------------------- MODULE MCTupleRecordSplat --------------------------
(* The tuple record model with the splat of a run-time arity and typeof of a *)
(* record (TupleRecordSplat.tla) over three slots of every static typing     *)
(* (concrete, nullable concrete, top, pinned top), every producer (the splat *)
(* among them) and every move between them. Claims: TupleRecord.tla's       *)
(* TopHoldsNoConcrete, IsaAgrees (over every tested type) and ValueKept, and *)
(* OneRepresentation, EgalAgrees, NarrowNeverArray, TypeofAgrees.            *)
(* Broken: MCTupleRecordSplatAlwaysArrayBroken.cfg (the splat always builds  *)
(* the array class: OneRepresentation), MCTupleRecordSplatAlwaysArrayEgal    *)
(* Broken.cfg (the same variant: EgalAgrees),                                *)
(* MCTupleRecordSplatHoldsOmitsArrayBroken.cfg (open_tuple_holds leaves the  *)
(* array class out of an uncovered fixed arity: IsaAgrees),                  *)
(* MCTupleRecordSplatTypeofAnswersRecordBroken.cfg (typeof answers the       *)
(* record class: TypeofAgrees).                                              *)
EXTENDS TupleRecordSplat
=============================================================================
