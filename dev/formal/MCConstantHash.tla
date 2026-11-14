-------------------------- MODULE MCConstantHash ------------------------------
(* The constant caches' key hash (src/julia/nir.jl _bounded_hash) over a       *)
(* universe of flat leaves, two mutable cells (one may hold itself) and       *)
(* immutables with sharing (a three-level chain, 15 paths), every Mutate of a *)
(* cell's contents explored. Claims: AgreesWithEgal, Bounded, StableKeys,     *)
(* FirstValuesTell. Broken: MCConstantHashUnboundedBroken.cfg (Bounded),      *)
(* MCConstantHashMutByContentBroken.cfg (StableKeys) and                      *)
(* MCConstantHashTypeOnlyBroken.cfg (FirstValuesTell).                        *)
EXTENDS ConstantHash
=============================================================================
