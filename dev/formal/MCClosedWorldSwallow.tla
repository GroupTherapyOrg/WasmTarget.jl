------------------------ MODULE MCClosedWorldSwallow -----------------------
(* THE BROKEN VARIANT (swallowed failure): same instance as                *)
(* MCClosedWorldReject (D fails to specialize, reachable only through the  *)
(* full alternation chain), but SwallowFailures = TRUE -- a try/catch that *)
(* silently drops the failing candidate instead of letting the throw       *)
(* abort the plan. D has no further outgoing edges, so the rest of the     *)
(* plan (R1,R2,A,B,C) collects to completion around the hole -- Done is    *)
(* reached with a plan silently missing a reachable method:                *)
(* FailureIsLoud must be violated (and, as a direct consequence,           *)
(* Completeness too).                                                     *)
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

MCSpecializeFails == {"D"}
MCRoundCeiling    == 0
MCSwallowFailures == TRUE
=============================================================================
