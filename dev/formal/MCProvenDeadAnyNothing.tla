---------------------------- MODULE MCProvenDeadAnyNothing ----------------------------
(* Every `nothing` in no block, not the trailing ones alone (TrailingOnly = FALSE): a reachable mid-body `nothing` reads as dead. *)
EXTENDS ProvenDead
MCN == 5
MCCondFallthrough == TRUE
MCCatchEdge == TRUE
MCTrailingOnly == FALSE
=============================================================================
