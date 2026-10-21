---------------------------- MODULE MCEnrollmentProduct ----------------------------
(* The enrollment's candidate product past the bound (the code's is 4096; Bound   *)
(* is set in the cfg). Classes I, J, S; z: zP admits every pair, with static       *)
(* parameters both positions mention (`h(x::T, y::S) where {T, S}`), so a call at  *)
(* every pair enumerates 3 x 3 = 9 candidate tuples, past a bound of 4: the call   *)
(* rejects (ProductBoundIsLoud), as the ambiguity search past the bound does. A   *)
(* call at `{I} x X` enumerates 1 x 3 tuples, within it. As at the search's bound,  *)
(* a rejection past the bound with no ambiguous tuple breaks                       *)
(* RejectOnlyWhenAmbiguous (Enrollment's header, A13P12), which this instance does *)
(* not check. MCEnrollmentProductUnboundedBroken enumerates past the bound.        *)
EXTENDS Enrollment
PRX == {"I", "J", "S"}
PRMethods == {"zP"}
PROwner == [m \in PRMethods |-> "z"]
PRParam == [m \in PRMethods |-> PRX \X PRX]
PRPOrd == [m \in PRMethods |-> 1]
PRPFix == [m \in PRMethods |-> {1, 2}]
PRStatics == {PRX \X PRX, {"I"} \X PRX}
PRNoFix == [m \in PRMethods |-> {}]
=============================================================================
