-------------------------- MODULE MCClosedWorldReject ----------------------
(* Six methods, two roots: R1 --invoke--> A (:new T1), R2 --invoke--> C  *)
(* (:new T2), R2 --dyn T1--> B --invoke--> C, B --dyn T2--> D. D (the     *)
(* deepest method -- reachable only once the dynamic scans have found B   *)
(* and then D) fails to specialize. Exercises FailureIsLoud               *)
(* NON-vacuously: adds `PROPERTY RejectReachable` to the .cfg, so TLC     *)
(* must confirm the Rejected path is genuinely taken, not merely never    *)
(* falsified.                                                             *)
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

RejectReachable == <>(status = "Rejected")
=============================================================================
