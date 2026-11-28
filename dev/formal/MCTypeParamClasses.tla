------------------------ MODULE MCTypeParamClasses ----------------------------
(* The pass over the closed world's classes after its walk (src/julia/classes.jl *)
(* closed_world_classes): each concrete tuple class's record and, where a type   *)
(* value is held, each class's type parameters, to the fixpoint, over a class    *)
(* whose parameter's supertype holds a parameter of its own (B <: SB{Q}), a       *)
(* tuple field and parameter brought to its record, Type{T}, DataType's supertype,*)
(* whose parameter is a type variable; every program of one or two seeds among    *)
(* A, Box2, DataType (a type value held) and Str. Claims: Once, ParamsClosed,     *)
(* RecordsClosed, NothingExtra, Terminates.                                       *)
(* Broken: MCTypeParamClasses{OneLevel,NoHeldGate,FreeFields}Broken.cfg, each its *)
(* header's claim.                                                                *)
EXTENDS TypeParamClasses
=============================================================================
