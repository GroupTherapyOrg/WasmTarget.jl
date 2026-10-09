----------------------- MODULE MCClosedWorldGarbage -----------------------
(* A DEAD materialized original -- b106's F1 shape, Widened:               *)
(*   R --invoke_in_world--> M; M --invoke--> O, retargeted to N;           *)
(*   O --invoke--> X; R :new T and R --dyn T--> X.                         *)
(* Reachable = {R, M, N, X}. compile! of M may materialize O               *)
(* (inlining.jl:795-799) and, through it, X; M's scan then retargets its  *)
(* site away from O, and no live site names it.                            *)
(*                                                                         *)
(* FINDING, pinned (dev/MARCH.md 13.17 H9 (C9)): a widened original        *)
(* compileable_specialization materializes may be collected unreached and  *)
(* compiled as dead code. Measured 0 over smoke and the probes (batch 107, *)
(* batch 111 Part 0) and over the 1.12 fuzz pass, seeds 0xCD 0x01 0x02     *)
(* (batch 107 alone). Fix: the collector asks which collected bodies a     *)
(* live edge reaches before codegen -- a reachability pass, not a trim, so *)
(* no body a live edge names is ever removed.                              *)
(*                                                                         *)
(* MCClosedWorldGarbageBroken.cfg violates NoGarbage: O is collected.     *)
(* MCClosedWorldGarbage.cfg checks that NoneMissing holds (X stays, since *)
(* nothing is dropped) and that every run ends Done; Completeness,        *)
(* the equality, fails here exactly by the pinned dead code. With          *)
(* c7f0c250's trim (MCClosedWorldTrimDropsBroken.cfg) the run drops O's    *)
(* subtree, X with it, and Completeness fails by a MISSING body.           *)
EXTENDS ClosedWorld

MCMethods == {"R", "M", "O", "N", "X"}
MCRoots   == {"R"}
MCTypes   == {"T"}
MCInvokeEdges == [m \in MCMethods |-> IF m = "M" THEN {"O"} ELSE IF m = "O" THEN {"X"} ELSE {}]
MCRetargets   == [m \in MCMethods |-> IF m = "M" THEN {<<"O", "N">>} ELSE {}]
MCTypeSites   == [m \in MCMethods |-> IF m = "R" THEN {"T"} ELSE {}]
MCDynSites    == [m \in MCMethods |-> IF m = "R" THEN {"T"} ELSE {}]
MCDynTargets  == [t \in MCTypes |-> {"X"}]
MCSpecializeFails == {}
MCRoundCeiling    == 0
MCSwallowFailures == FALSE
MCHiddenEdges     == [m \in MCMethods |-> IF m = "R" THEN {<<"M", "invoke_in_world">>} ELSE {}]
MCWidened         == {"O"}
MCUnmaterialized  == {}
MCCollectorKinds  == HiddenKinds
MCTrim            == FALSE
MCFmaEdges        == [m \in MCMethods |-> {}]
MCExternalLeaves  == {}
MCLateCut         == TRUE

(* the superseded original is dead: no site of the program names it *)
ASSUME "O" \in AllOriginals /\ "O" \notin Reachable
=============================================================================
