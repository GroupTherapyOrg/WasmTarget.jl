-------------------------- MODULE MCValueClasses -------------------------------
(* The closed world's classes (src/julia/classes.jl closed_world_classes,     *)
(* _meet_value!, _meet_class!) over a universe of abstract and concrete       *)
(* classes, a recursive struct (Node), a struct of two fields (Pair) and two  *)
(* kinds, for every program of one or two value types among a DataType, a     *)
(* Union, a Vararg, Type{X} of a DataType, of a Union and of an unknown T, a  *)
(* UnionAll under Type and Union{}. Claims: Once, ValuesCovered,              *)
(* SupertypeClosed, FieldsClosed, NothingExtra, Terminates. Broken:           *)
(* MCValueClasses{NoSeenGuard,KindOnly,NoSupertype,NoFields,KindsAlways}      *)
(* Broken.cfg, each its header's claim.                                       *)
EXTENDS ValueClasses
=============================================================================
