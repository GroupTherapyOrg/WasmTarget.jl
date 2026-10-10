---------------------- MODULE MCClosedWorldRoundCeiling --------------------
(* THE BROKEN VARIANT (round ceiling): the MCClosedWorldReject shape       *)
(* without the failure, and RoundCeiling = 1 -- the retired                *)
(* `for _round in 1:8`-style outer-loop cap L78 forbids. compile! of the    *)
(* roots collects R1, R2, A and C; reaching Done then needs 2 enrolling     *)
(* scans in every interleaving (the dynamic candidates B, then D), so a cap *)
(* of 1 forces ForceStopAtCeiling to fire while D is still missing in every *)
(* behavior -- Completeness must be violated.                              *)
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
MCRoundCeiling    == 1
MCSwallowFailures == FALSE
MCRetargets       == [m \in MCMethods |-> {}]
MCHiddenEdges     == [m \in MCMethods |-> {}]
MCFmaEdges        == [m \in MCMethods |-> {}]
MCExternalLeaves  == {}
MCLateCut         == TRUE
MCWidened         == {}
MCUnmaterialized  == {}
MCCollectorKinds  == HiddenKinds
MCTrim            == FALSE
=============================================================================
