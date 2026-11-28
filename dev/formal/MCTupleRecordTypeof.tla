------------------------- MODULE MCTupleRecordTypeof -------------------------
(* typeof of a tuple record (TupleRecordTypeof.tla) over three slots of     *)
(* every static typing (concrete, nullable concrete, top, pinned top, mixed  *)
(* top), every producer (the splat and a value of no tuple type among them)  *)
(* and every move between them. Claims: TopHoldsNoConcrete, IsaAgrees,       *)
(* ValueKept, OneRepresentation, EgalAgrees, NarrowNeverArray, TypeofAgrees, *)
(* PinnedAnswers.                                                            *)
(* Broken, each refuted by TypeofAgrees: MCTupleRecordTypeofAnswersRecord    *)
(* Broken.cfg (typeof answers the record class),                             *)
(* MCTupleRecordTypeofArmsOmitBoxRecordBroken.cfg (the box record without an *)
(* arm, its null table entry read), MCTupleRecordTypeofFatalIsException      *)
(* Broken.cfg (the gap an exception a catch observes).                       *)
EXTENDS TupleRecordTypeof
=============================================================================
