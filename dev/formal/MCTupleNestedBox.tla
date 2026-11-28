-------------------------- MODULE MCTupleNestedBox --------------------------
(* convertType's box and unbox of nested tuples through one function per    *)
(* tuple type (TupleNestedBox.tla), over every tuple type of depth up to 3.  *)
(* Claims: BoxAgrees, UnboxAgrees. Broken: MCTupleNestedBoxShallowBoxBroken.cfg *)
(* (BoxAgrees), MCTupleNestedBoxShallowUnboxBroken.cfg (UnboxAgrees).        *)
EXTENDS TupleNestedBox
=============================================================================
