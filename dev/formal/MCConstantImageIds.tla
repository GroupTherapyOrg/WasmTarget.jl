------------------------ MODULE MCConstantImageIds ---------------------------
(* A constant's image id (src/julia/runtime/hashing.jl image_slot!,           *)
(* image_object_id; src/julia/classes.jl memory_constant_object) over two     *)
(* distinct constants of equal contents, a Memory reached through its live    *)
(* copy by two Arrays, two objects made at run time with two serials, and a   *)
(* compile that may place a constant below 2^31. Claims: AgreesWithEgal,      *)
(* Unique. Broken: MCConstantImageIdsCopyOwnKeyBroken.cfg (AgreesWithEgal)    *)
(* and MCConstantImageIdsNoCollisionCheckBroken.cfg (Unique).                 *)
EXTENDS ConstantImageIds
=============================================================================
