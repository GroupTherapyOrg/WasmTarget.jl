---------------------------- MODULE MCProvenDeadNoCatchEdge ----------------------------
(* An Enter's catch edge dropped (CatchEdge = FALSE): a handler reached only by an exception reads as dead. *)
EXTENDS ProvenDead
MCN == 5
MCCondFallthrough == TRUE
MCCatchEdge == FALSE
MCTrailingOnly == TRUE
=============================================================================
