--------------------- MODULE MCObjectIdentityStrings --------------------------
(* ObjectIdentity's instance (MCObjectIdentity's universe and constants) with  *)
(* objectid of a String beside it (ObjectIdentityStrings.tla), under SpecS.    *)
(* Claims: TypeOKS, AgreesWithEgal, Unique, DataIdsExact, NoWrap,             *)
(* WriteSeenSameConstant, WriteUnseenDistinctConstants, ConstantDataAgrees,   *)
(* StringSlotDataOnly. Broken: MCObjectIdentityStringsSlotReadBroken.cfg      *)
(* (StringSlotDataOnly).                                                      *)
EXTENDS ObjectIdentityStrings
=============================================================================
