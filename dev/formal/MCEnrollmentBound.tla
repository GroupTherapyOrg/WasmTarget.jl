---------------------------- MODULE MCEnrollmentBound ----------------------------
(* MCEnrollment's instance with a bound small enough that overlaps exceed it    *)
(* (the code's is 4096; Bound is set in the cfg). Every pair is a value; the    *)
(* static types add `{I} x X` (`h(x::Int64, y)`): over it q's pair q1/q2 is      *)
(* Base.isambiguous with an overlap of 1 x 6 = 6 candidate tuples, and no tuple  *)
(* is ambiguous (q3 is more specific than both). Past a bound below 6 the       *)
(* callable rejects with nothing ambiguous (RejectOnlyWhenAmbiguous's second     *)
(* disjunct, the code's behavior, A8C8); over every pair the same pair's        *)
(* overlap `{I, J} x X` (12 tuples) holds the ambiguous (J, _), which            *)
(* BoundAccepts (broken) runs as a row. b's pair b1/b2 (`{I} x X`, 6 tuples) is  *)
(* past the bound too and ambiguous at every I.                                  *)
EXTENDS MCEnrollment
MCBoundStatics == MCStatics \cup {Row({"I"})}
=============================================================================
