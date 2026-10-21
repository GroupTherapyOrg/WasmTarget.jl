------------------------- MODULE MCEnrollmentArity --------------------------
(* Two functions: f builds c1 (it accepts arity 1) and makes a zero-argument *)
(* dynamic call; g builds c2 (it accepts arities 0 and 1) and makes an        *)
(* arity-1 call. Each closure is called only in the function that does not  *)
(* build it at one of its arities, so the fold alone misses c1@1 and c2@0,   *)
(* and dropping arity 0 misses c2@0.                                         *)
EXTENDS EnrollmentArity
MCFns == {"f", "g"}
MCClosures == {"c1", "c2"}
MCBuilds == [x \in MCFns |-> IF x = "f" THEN {"c1"} ELSE {"c2"}]
MCCalls == [x \in MCFns |-> IF x = "f" THEN {0} ELSE {1}]
MCAccepts == [c \in MCClosures |-> IF c = "c1" THEN {1} ELSE {0, 1}]
=============================================================================
