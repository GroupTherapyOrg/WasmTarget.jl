-------------------------- MODULE MCNirBuildSwallow --------------------------
(* Claim (5) UNSUPPORTED-IS-LOUD in isolation: ConsumerSwallowsUnsupported      *)
(* makes a migrated consumer treat s13 (ExprSplatnew, no lowering anywhere) as   *)
(* a silent no-op instead of routing it to record_unsupported! -- the historical *)
(* silent-fallthrough failure mode nir.jl's own docstring (:160-162) forbids.    *)
(* Exists only to pair with MCNirBuildSwallowBroken.cfg -- see                    *)
(* MCNirBuildCensusDrop.tla's header for why no separate positive `.cfg`           *)
(* accompanies it. *)
EXTENDS MCNirBuild
=============================================================================
