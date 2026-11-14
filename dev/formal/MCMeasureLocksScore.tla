------------------------ MODULE MCMeasureLocksScore ------------------------
(* The measurement locks with one slot's measurement and the scoreboard's     *)
(* (the score lock and the `score` role, which the landing takes first), the  *)
(* lander's two rounds of LAND or REB, one death and one reused pid: the same *)
(* claims as MCMeasureLocks, whose instance has two slots.                    *)
EXTENDS MeasureLocks
=============================================================================
