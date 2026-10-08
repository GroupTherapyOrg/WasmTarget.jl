---------------------------- MODULE MCEnrollmentBoundOverReject ----------------------------
(* Today's code past the bound: the open over-rejection A8C8 on dev/MARCH.md    *)
(* 13.17; when A8C8 is fixed, this becomes a positive instance.                  *)
(* MCEnrollmentBound's constants (Bound below 6, BoundAccepts FALSE), checked    *)
(* against every claim: the code rejects q over `{I} x X`, whose q1/q2 overlap   *)
(* (6 candidate tuples) is past the bound and holds no ambiguous tuple, so TLC   *)
(* must report exactly RejectOnlyWhenAmbiguous violated (MCEnrollmentBound.cfg   *)
(* shows the other claims hold over the same constants).                         *)
EXTENDS MCEnrollmentBound
=============================================================================
