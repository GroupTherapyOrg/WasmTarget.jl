-------------------------- MODULE MCCoercion --------------------------------
(* Model-checking instance for Coercion.tla: the whole finite lattice (4      *)
(* numerics + 20 ref kinds x 2 nullabilities = 44 types), every ordered pair, *)
(* each of the four source readings (SrcKinds) — 7744 triples, each an       *)
(* initial state. Nothing is sampled: the instance IS the exhaustive check.   *)
(***************************************************************************)
EXTENDS Coercion
=============================================================================
