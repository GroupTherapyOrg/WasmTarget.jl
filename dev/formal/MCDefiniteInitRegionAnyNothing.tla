---------------------------- MODULE MCDefiniteInitRegionAnyNothing ----------------------------
(* Every `nothing` in no block, not the trailing ones alone (TrailingOnly = FALSE). *)
EXTENDS DefiniteInit
MCN == 4
MCMeet == "Intersect"
MCCatchEdge == TRUE
MCUpsilonIsUse == TRUE
MCTrailingOnly == FALSE
MCExt == TRUE
=============================================================================
