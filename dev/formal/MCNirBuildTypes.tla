-------------------------- MODULE MCNirBuildTypes --------------------------
(* Claim (4) NO-RE-DERIVATION in isolation: TypeRederiveBug makes s8 (PhiNode)   *)
(* carry a hypothetical second, independent type computation (AnyTy) instead    *)
(* of `ctx.ssa_types`' answer (Float64Ty) -- the exact drift the R3/R5 ratchets  *)
(* exist to keep out of nir.jl. Exists only to pair with                          *)
(* MCNirBuildTypesBroken.cfg -- see MCNirBuildCensusDrop.tla's header for why       *)
(* no separate positive `.cfg` accompanies it. *)
EXTENDS MCNirBuild
=============================================================================
