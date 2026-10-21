--------------------- MODULE MCClosedWorldTypingNarrow ---------------------
(* The round-dependent typing's narrowing direction (ClosedWorld.tla,      *)
(* ROUND-DEPENDENT TYPING).                                                *)
(*                                                                         *)
(*   R --invoke--> O (Julia's abstract MI), whose operand is a captured    *)
(*        variable erased while its creator K is outside the world (its    *)
(*        base unknown), exact once K is collected, so the scan then       *)
(*        retargets O to N                                                 *)
(*   R --:new T1-->[observed];  R --dyn T1--> K (the creator, reached      *)
(*        through a dynamic call)                                          *)
(*                                                                         *)
(* R's first scan runs before the dynamic step collects K: O stays. The    *)
(* code recomputes the site next round and retargets it to N, which it     *)
(* enrolls; ReTypeOnlyRestores (MCClosedWorldTypingNarrowRestoreOnlyBroken) *)
(* recomputes a site only to undo a retarget, and the IR keeps O where the *)
(* final typing selects N.                                                 *)
EXTENDS ClosedWorld

TNMethods == {"R", "O", "N", "K"}
TNRoots   == {"R"}
TNTypes   == {"T1"}
TNInvokeEdges == [m \in TNMethods |-> IF m = "R" THEN {"O"} ELSE {}]
TNEmptyPairs  == [m \in TNMethods |-> {}]
TNTypeSites   == [m \in TNMethods |-> IF m = "R" THEN {"T1"} ELSE {}]
TNDynSites    == [m \in TNMethods |-> IF m = "R" THEN {"T1"} ELSE {}]
TNDynTargets  == [t \in TNTypes |-> {"K"}]
TNEmptySets   == [m \in TNMethods |-> {}]
TNTypedRetargets == [m \in TNMethods |-> IF m = "R" THEN {<<"O", "N", "K", "narrow">>} ELSE {}]
TNRestoreOnly == TRUE

(* a typed site's original is an :invoke edge Julia wrote *)
ASSUME \A m \in TNMethods : \A t \in TNTypedRetargets[m] : t[1] \in TNInvokeEdges[m]
=============================================================================
