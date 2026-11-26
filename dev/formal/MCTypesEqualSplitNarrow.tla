---------------------- MODULE MCTypesEqualSplitNarrow ------------------------
(* The run-time lookup of jl_types_equal's cache with both operands narrow,  *)
(* unions of Type{X}: two left values against three right ones, one pair     *)
(* distinct yet equal (TypeofBottom and Type{Union{}}), every key order.     *)
(* Claims: Total, Agrees.                                                    *)
EXTENDS TypesEqualSplit
MCVals == {"A", "C", "TB", "TU"}
MCEq == {<<v, v>> : v \in MCVals} \cup {<<"TB", "TU">>, <<"TU", "TB">>}
=============================================================================
