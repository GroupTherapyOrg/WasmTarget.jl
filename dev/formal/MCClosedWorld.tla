------------------------ MODULE MCClosedWorld -----------------------------
(* The code: an unconditional fixpoint, no swallowed failure, no trim,    *)
(* one hidden-edge relation for the collector, the fma bodies collected.   *)
(*                                                                         *)
(* Instance shape (9 methods, 1 root). Every mechanism is load-bearing: a  *)
(* method below is reachable only through the edge drawn to it.            *)
(*                                                                         *)
(*   R --invoke--> A --:new T1-->[observed]                                *)
(*   R --dyn T1--> B                                                       *)
(*   B --invoke--> O, retargeted to N   (O: Julia's abstract MI, which     *)
(*                                       compile! of B does not            *)
(*                                       materialize here; superseded by   *)
(*                                       B's scan)                         *)
(*   N --:new T2-->[observed]                                              *)
(*   B --dyn T2--> D                                                       *)
(*   A --hidden invoke_in_world--> E --hidden splat--> S                   *)
(*   E --muladd_float--> F   (Base.fma_emulated)                           *)
(*                                                                         *)
(* D is discoverable only once B was found by a dynamic scan, scanned by   *)
(* the invoke scan (which retargets O to N), and N collected -- each       *)
(* mechanism feeds the next (L78). The A2C1 kinds are MCClosedWorldKinds', *)
(* the imports MCClosedWorldLeaves'.                                       *)
EXTENDS ClosedWorld

MCMethods == {"R", "A", "B", "O", "N", "D", "E", "S", "F"}
MCRoots   == {"R"}
MCTypes   == {"T1", "T2"}

MCInvokeEdges == [m \in MCMethods |->
    IF   m = "R" THEN {"A"}
    ELSE IF m = "B" THEN {"O"}
    ELSE {}]

MCRetargets == [m \in MCMethods |-> IF m = "B" THEN {<<"O", "N">>} ELSE {}]

MCTypeSites == [m \in MCMethods |->
    IF   m = "A" THEN {"T1"}
    ELSE IF m = "N" THEN {"T2"}
    ELSE {}]

MCDynSites == [m \in MCMethods |->
    IF   m = "R" THEN {"T1"}
    ELSE IF m = "B" THEN {"T2"}
    ELSE {}]

MCDynTargets == [t \in MCTypes |->
    IF t = "T1" THEN {"B"} ELSE {"D"}]

MCSpecializeFails == {}
MCRoundCeiling    == 0
MCSwallowFailures == FALSE
MCHiddenEdges     == [m \in MCMethods |->
    IF   m = "A" THEN {<<"E", "invoke_in_world">>}
    ELSE IF m = "E" THEN {<<"S", "splat">>}
    ELSE {}]
MCWidened         == {}
MCUnmaterialized  == {"O"}
MCCollectorKinds  == HiddenKinds
MCTrim            == FALSE
MCFmaEdges        == [m \in MCMethods |-> IF m = "E" THEN {"F"} ELSE {}]
MCExternalLeaves  == {}
MCLateCut         == TRUE

(* the instance uses both of WT's own hidden kinds *)
ASSUME {p[2] : p \in UNION {MCHiddenEdges[m] : m \in MCMethods}} = WTKinds

(* a retarget replaces an original that is not a root *)
ASSUME \E m \in MCMethods : \E p \in MCRetargets[m] : p[1] \notin MCRoots

(* this instance's original is never materialized (MCClosedWorldGarbage's is) *)
ASSUME OriginalsUnmaterialized
=============================================================================
