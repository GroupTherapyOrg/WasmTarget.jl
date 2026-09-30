---------------------- MODULE MCClosedWorldPrune ---------------------------
(* THE BROKEN VARIANT (a trim smaller than discovery): MCClosedWorld's     *)
(* instance, but the pruner walks only :invoke edges -- the retired        *)
(* pruner that knew the runtime-Vararg splat edge and not invoke_in_world's *)
(* (PrunerSeesHidden = FALSE). E, reachable from A only through a hidden   *)
(* call, is collected, pruned, and never proposed again: Done is reached   *)
(* with a plan missing a reachable method -- Completeness must be violated. *)
EXTENDS ClosedWorld

MCMethods == {"R1", "R2", "A", "B", "C", "D", "E"}
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
MCHiddenEdges     == [m \in MCMethods |-> IF m = "A" THEN {"E"} ELSE {}]
MCPrunerSeesHidden == FALSE
=============================================================================
