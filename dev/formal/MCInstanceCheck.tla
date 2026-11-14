--------------------------- MODULE MCInstanceCheck ---------------------------
(* Every closed world of one to three of the lattice's 11 concrete classes,   *)
(* every value of it (an instance or a type value) and every tested DataType: *)
(* the run-time instance check answers Julia's isa (CheckIsJuliaIsa).         *)
(* Broken, each CheckIsJuliaIsa violated: MCInstanceCheckNoTupleArmBroken.cfg *)
(* (a Tuple type through the class table), MCInstanceCheckNoTypeArmBroken.cfg *)
(* (Type{X} through the class table) and                                      *)
(* MCInstanceCheckOwnChainsOnlyBroken.cfg (a Tuple's element classes          *)
(* unnumbered).                                                                *)
EXTENDS InstanceCheck
=============================================================================
