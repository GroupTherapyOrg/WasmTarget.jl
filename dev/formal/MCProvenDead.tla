---------------------------- MODULE MCProvenDead ----------------------------
(* Every program of 5 statements (an Enter and a :leave among the kinds); the real worklist. *)
EXTENDS ProvenDead
MCN == 5
MCCondFallthrough == TRUE
MCCatchEdge == TRUE
=============================================================================
