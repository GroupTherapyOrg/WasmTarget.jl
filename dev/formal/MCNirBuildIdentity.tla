-------------------------- MODULE MCNirBuildIdentity --------------------------
(* Claim (3) IDENTITY-ONCE in isolation: DivergentResolveBug makes a duplicated  *)
(* invoke-resolution site (modeling invoke.jl's ~4 ad hoc sites, e.g. :1469-     *)
(* 1473) forget the CodeInstance-unwrap arm, so it disagrees with s4's           *)
(* once-resolved `nir[4].mi` (OperandShape=WrappedInCI). Exists only to pair       *)
(* with MCNirBuildIdentityBroken.cfg -- see MCNirBuildCensusDrop.tla's header       *)
(* for why no separate positive `.cfg` accompanies it. *)
EXTENDS MCNirBuild
=============================================================================
