---------------------------- MODULE MCEnrollmentBoundOverReject ----------------------------
(* Today's code past the bound: the open over-rejection A8C8 on dev/MARCH.md      *)
(* 13.17. MCEnrollmentBound's constants (Bound below 6, BoundAccepts FALSE),      *)
(* checked against every claim: the code rejects q over `{I} x X`, whose q1/q2    *)
(* overlap (6 candidate tuples) is past the bound and holds no ambiguous tuple,   *)
(* so TLC must report exactly RejectOnlyWhenAmbiguous violated                    *)
(* (MCEnrollmentBound.cfg shows the other claims hold over the same constants).   *)
(* Fixing A8C8 does not by itself make this a positive instance. At these         *)
(* constants q over `{I} x X` is Unaskable and holds no ambiguous tuple, so       *)
(* BoundIsLoud requires a rejection there and RejectOnlyWhenAmbiguous forbids     *)
(* one: no entry satisfies every claim, and the other answer at the bound,        *)
(* accepting (BoundAccepts), breaks BoundIsLoud instead                           *)
(* (MCEnrollmentBoundAcceptsBroken). The instance can turn positive only when     *)
(* A8C8's fix also restates the bound's claim as Julia requires it (past the      *)
(* bound, no row runs where Julia answers Ambig), or retires BoundIsLoud with the *)
(* bound.                                                                         *)
EXTENDS MCEnrollmentBound
=============================================================================
