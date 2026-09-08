---------------------- MODULE MCClosedWorldRoundCeiling --------------------
(* THE BROKEN VARIANT (round ceiling): same instance as MCClosedWorld, but *)
(* RoundCeiling = 3 -- the retired `for _round in 1:8`-style outer-loop    *)
(* cap L78 forbids. Reaching Done here requires 6 discovery steps in every *)
(* possible interleaving (4 CollectMethod on A/B/C/D + 2 DiscoverDynamic   *)
(* on B/D, order-independent in COUNT though not in sequence), so a cap of *)
(* 3 forces ForceStopAtCeiling to fire while the plan is still missing     *)
(* reachable methods in every behavior -- Completeness must be violated.   *)
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
MCRoundCeiling    == 3
MCSwallowFailures == FALSE
=============================================================================
