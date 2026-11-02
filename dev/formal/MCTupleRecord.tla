---------------------------- MODULE MCTupleRecord ----------------------------
(* The tuple record model's arms (TupleRecord.tla) over three slots of every *)
(* static typing (concrete, nullable concrete, top), every producer and every *)
(* move between them. Claims: TopHoldsNoConcrete, IsaAgrees, ValueKept.       *)
(* Broken: MCTupleRecordProducerSkipsBoxBroken.cfg (a tuple constant left as  *)
(* Tc in a top slot: TopHoldsNoConcrete), MCTupleRecordBoxNullBroken.cfg (the *)
(* box makes a record of a null: IsaAgrees).                                  *)
EXTENDS TupleRecord
=============================================================================
