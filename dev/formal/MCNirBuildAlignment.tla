-------------------------- MODULE MCNirBuildAlignment --------------------------
(* Claim (2) ALIGNMENT in isolation: AlignmentBug shifts positions >= 10, so     *)
(* `nir[10..12]` describe the WRONG (next) statement and position 13 (the true   *)
(* last statement) gets no NIR entry at all ("Missing"). Exists only to pair       *)
(* with MCNirBuildAlignmentBroken.cfg -- see MCNirBuildCensusDrop.tla's header      *)
(* for why no separate positive `.cfg` accompanies it. *)
EXTENDS MCNirBuild
=============================================================================
