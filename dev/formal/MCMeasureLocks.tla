--------------------------- MODULE MCMeasureLocks ---------------------------
(* The climb's measurement locks (dev/climb/measure.py julia_slot, yield_slot, *)
(* pause_in_place; dev/climb/lander.py land(), the rebased check, the layer):  *)
(* the lander's two rounds of LAND, REB or LAYER, two slots' measurements,    *)
(* one death and one reused pid anywhere (MCMeasureLocksScore: a slot and the *)
(* scoreboard). Claims:                                                       *)
(* NoCheckBesideRunning, OneRoleHolder, DeadMarksHoldNobody, Ends (which     *)
(* holds PausedResumes: every measurement ends), and TLC's deadlock check. Broken: MCMeasureLocks{F1Deadlock, *)
(* NoRecheck,StopUnverified,PidReuse,ContUnheld}Broken.cfg, each its header's claim. *)
EXTENDS MeasureLocks
=============================================================================
