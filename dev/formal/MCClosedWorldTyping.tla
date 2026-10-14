--------------------- MODULE MCClosedWorldTyping ---------------------------
(* The round-dependent typing (ClosedWorld.tla, ROUND-DEPENDENT TYPING).   *)
(*                                                                         *)
(*   R --invoke--> O (Julia's abstract MI, never materialized), whose      *)
(*        operand is a captured variable: exact (Int64) while the captor   *)
(*        C is not collected, so the scan retargets O to N (`g(::Int64)`)  *)
(*   R --:new T1-->[observed];  R --dyn T1--> C (the captor, a writer of   *)
(*        2.5 reached through a dynamic call)                              *)
(*                                                                         *)
(* R's scan may run before the dynamic step collects C, as the code's      *)
(* round runs it. The code recomputes the site next round from O and       *)
(* restores it; InPlaceRetarget (MCClosedWorldTypingInPlaceRetargetBroken) *)
(* keeps N, and the program calls N with a Float64.                        *)
EXTENDS ClosedWorld

TYMethods == {"R", "O", "N", "C"}
TYRoots   == {"R"}
TYTypes   == {"T1"}
TYInvokeEdges == [m \in TYMethods |-> IF m = "R" THEN {"O"} ELSE {}]
TYEmptyPairs  == [m \in TYMethods |-> {}]
TYTypeSites   == [m \in TYMethods |-> IF m = "R" THEN {"T1"} ELSE {}]
TYDynSites    == [m \in TYMethods |-> IF m = "R" THEN {"T1"} ELSE {}]
TYDynTargets  == [t \in TYTypes |-> {"C"}]
TYEmptySets   == [m \in TYMethods |-> {}]
TYTypedRetargets == [m \in TYMethods |-> IF m = "R" THEN {<<"O", "N", "C">>} ELSE {}]
TYInPlace     == TRUE

(* a typed site's original is an :invoke edge Julia wrote *)
ASSUME \A m \in TYMethods : \A t \in TYTypedRetargets[m] : t[1] \in TYInvokeEdges[m]
=============================================================================
