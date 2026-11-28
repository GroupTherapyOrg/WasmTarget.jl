------------------------- MODULE MCTypeParamValues -------------------------
(* the pass over a held class's parameter values (TypeParamValues.tla), over  *)
(* every program of the four seed classes, a type value held or not.        *)
(* Claims: TypeValuesMade, NoVarargClass. Broken:                             *)
(* MCTypeParamValuesTypesOnlyBroken.cfg (TypeValuesMade),                    *)
(* MCTypeParamValuesMeetsVarargBroken.cfg (NoVarargClass).                   *)
EXTENDS TypeParamValues
=============================================================================
