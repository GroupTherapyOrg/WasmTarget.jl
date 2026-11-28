------------------------------ MODULE MCTypesEgal ----------------------------
(* egal_types (julia/src/builtins.c:167) and its port's walk, over every     *)
(* pair of TypesEgal's UnionAlls. Claims: Agrees, AgreesAlpha, JuliaIsAlpha, *)
(* GapOnlyAtDataTypes, Ends. Broken: MCTypesEgalIdentityBroken.cfg,          *)
(* MCTypesEgalNoEnvBroken.cfg, MCTypesEgalNoNameBroken.cfg (Agrees),         *)
(* MCTypesEgalAlphaEverywhereBroken.cfg (AgreesAlpha).                       *)
EXTENDS TypesEgal
=============================================================================
