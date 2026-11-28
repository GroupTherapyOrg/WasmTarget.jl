------------------------- MODULE MCTypesEqualSplit ---------------------------
(* The run-time lookup of jl_types_equal's cache (src/intrinsics.jl, the     *)
(* types_equal arm) with the second operand typed DataType (wide), the       *)
(* shape of a Dict keyed by types: two left values of the identity premise   *)
(* (a struct, a parametric struct's instance) against five values, two of    *)
(* them distinct yet equal (TypeofBottom and Type{Union{}}), every order.    *)
(* Claims: Total, Agrees. Broken: MCTypesEqualSplitRestFirstBroken.cfg and   *)
(* MCTypesEqualSplitNoPremiseBroken.cfg (Agrees).                            *)
EXTENDS TypesEqualSplit
MCVals == {"A", "C", "F", "TB", "TU"}
MCEq == {<<v, v>> : v \in MCVals} \cup {<<"TB", "TU">>, <<"TU", "TB">>}
MCLeft == {"A", "C"}
\* a left value equal to another value than itself: TypeofBottom
MCLeftBottom == {"A", "TB"}
=============================================================================
