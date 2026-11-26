--------------------------- MODULE MCKindFieldTable ---------------------------
(* A DataType's own field read at run time from its per-field table by class *)
(* id (KindFieldTable.tla), over every receiver of five classes and three    *)
(* fields. Claims: ReadAgrees, ReadAnswers, SuperClosed. Broken, each        *)
(* refuted by ReadAgrees: MCKindFieldTableNullIsUndefBroken.cfg,             *)
(* MCKindFieldTableGapIsNullBroken.cfg.                                      *)
EXTENDS KindFieldTable
=============================================================================
