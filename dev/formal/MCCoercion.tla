-------------------------- MODULE MCCoercion --------------------------------
(* Model-checking instance for Coercion.tla: the whole finite lattice (4      *)
(* numerics + 17 ref kinds x 2 nullabilities = 38 types), every ordered pair, *)
(* both settings of the concrete-Julia-source flag — 2888 triples, walked one *)
(* per step. Nothing is sampled: the instance IS the exhaustive check.        *)
(***************************************************************************)
EXTENDS Coercion
=============================================================================
