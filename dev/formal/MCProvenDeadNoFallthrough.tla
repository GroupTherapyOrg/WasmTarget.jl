---------------------------- MODULE MCProvenDeadNoFallthrough ----------------------------
(* A goto-if-not treated like a goto: its fall-through block is dropped (CondFallthrough = FALSE). *)
EXTENDS ProvenDead
MCN == 5
MCCondFallthrough == FALSE
=============================================================================
