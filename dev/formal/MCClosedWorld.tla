------------------------ MODULE MCClosedWorld -----------------------------
(* The real algorithm: unconditional fixpoint, no swallowed failures.      *)
(*                                                                         *)
(* Instance shape (6 methods, 2 roots -- deliberately needs BOTH discovery *)
(* mechanisms to alternate to reach full reachability, and gives TLC real  *)
(* order nondeterminism to explore):                                       *)
(*                                                                         *)
(*   R1 --invoke--> A --:new T1-->[observed]                               *)
(*   R2 --invoke--> C --:new T2-->[observed]                               *)
(*   R2 --dyn T1--> B --invoke--> C   (also reached directly from R2)      *)
(*   B  --dyn T2--> D                                                     *)
(*                                                                         *)
(* D is only discoverable once BOTH T1 (from A) and T2 (from C) have been  *)
(* observed AND B has been collected -- exactly the cross-mechanism        *)
(* dependency that makes a single shared fixpoint necessary (L78): running *)
(* dynamic-dispatch discovery to a fixpoint once, then invoke discovery    *)
(* once, would still miss D discovered via B's dynamic site after B itself *)
(* was found by an EARLIER dynamic-discovery pass.                         *)
EXTENDS ClosedWorld

MCMethods == {"R1", "R2", "A", "B", "C", "D"}
MCRoots   == {"R1", "R2"}
MCTypes   == {"T1", "T2"}

MCInvokeEdges == [m \in MCMethods |->
    IF   m = "R1" THEN {"A"}
    ELSE IF m = "R2" THEN {"C"}
    ELSE IF m = "B"  THEN {"C"}
    ELSE {}]

MCTypeSites == [m \in MCMethods |->
    IF   m = "A" THEN {"T1"}
    ELSE IF m = "C" THEN {"T2"}
    ELSE {}]

MCDynSites == [m \in MCMethods |->
    IF   m = "R2" THEN {"T1"}
    ELSE IF m = "B" THEN {"T2"}
    ELSE {}]

MCDynTargets == [t \in MCTypes |->
    IF t = "T1" THEN {"B"} ELSE {"D"}]

MCSpecializeFails == {}
MCRoundCeiling    == 0
MCSwallowFailures == FALSE
=============================================================================
