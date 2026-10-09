------------------------ MODULE MCClosedWorldMixed ------------------------
(* A LIVE original (Amendment 1; Part M's Finding 2). `@nospecialize g`:   *)
(*   H1(x::Int) = g(x)  -- concrete operands: the scan retargets           *)
(*                         g(::Any) (A) to g(::Int) (A2), superseding A;   *)
(*   H2(x::Any) = g(x)  -- not concrete: keeps A, which stays live.        *)
(* A is Widened: compile! may materialize it (inlining.jl:795-799, when    *)
(* g(::Any) was inferred in the partition) or not, in which case H2's scan *)
(* enrolls it. Either way the plan is exactly {H1, H2, A, A2}: Completeness*)
(* and EndsDone hold.                                                      *)
EXTENDS ClosedWorld

MCMethods == {"H1", "H2", "A", "A2"}
MCRoots   == {"H1", "H2"}
MCTypes   == {"T"}
MCInvokeEdges == [m \in MCMethods |-> IF m \in {"H1", "H2"} THEN {"A"} ELSE {}]
MCRetargets   == [m \in MCMethods |-> IF m = "H1" THEN {<<"A", "A2">>} ELSE {}]
MCTypeSites   == [m \in MCMethods |-> {}]
MCDynSites    == [m \in MCMethods |-> {}]
MCDynTargets  == [t \in MCTypes |-> {}]
MCSpecializeFails == {}
MCRoundCeiling    == 0
MCSwallowFailures == FALSE
MCHiddenEdges     == [m \in MCMethods |-> {}]
MCWidened         == {"A"}
MCUnmaterialized  == {}
MCCollectorKinds  == HiddenKinds
MCTrim            == FALSE
MCFmaEdges        == [m \in MCMethods |-> {}]
MCExternalLeaves  == {}
MCLateCut         == TRUE

(* the superseded original is live: an unretargeted site still names it *)
ASSUME "A" \in AllOriginals /\ "A" \in Reachable
=============================================================================
