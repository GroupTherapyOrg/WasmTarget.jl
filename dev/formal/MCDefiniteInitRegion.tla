---------------------------- MODULE MCDefiniteInitRegion ----------------------------
(* Every well-formed program of 4 statements, `nothing`s, upsilons and PhiCs among the kinds, start_pc any statement (a try body's included); the real proof. *)
EXTENDS DefiniteInit
MCN == 4
MCMeet == "Intersect"
MCCatchEdge == TRUE
MCUpsilonIsUse == TRUE
MCTrailingOnly == TRUE
MCExt == TRUE
=============================================================================
