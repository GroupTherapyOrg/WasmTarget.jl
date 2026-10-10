-------------------------- MODULE MCNirBuildCensusDrop --------------------------
(* Claim (1) TOTALITY in isolation: CensusDropBug corrupts s13 (ExprSplatnew,   *)
(* real-classified "Unsupported") into the illegal "SilentNoOpAtBuild" pseudo-  *)
(* value -- the exact p53 shape (an early no-op arm intercepting a head before   *)
(* the census's final `else` can reject it). TypeOK still holds (that value is   *)
(* in classKind's declared range); only NoVanishing catches it. Exists only to   *)
(* pair with MCNirBuildCensusDropBroken.cfg (run_tlc.sh strips "Broken.cfg" to    *)
(* find its `.tla`) -- the unperturbed positive case is already checked, for      *)
(* every claim, by MCNirBuild.cfg; a separate positive `.cfg` here would re-run    *)
(* the identical 8192-state space and add nothing. *)
EXTENDS MCNirBuild
=============================================================================
