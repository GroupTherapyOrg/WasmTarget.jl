------------------------ MODULE MCClosedWorldKinds ------------------------
(* A2C1's four edge kinds -- the edges Julia's collectinvokes! follows     *)
(* besides :invoke -- next to WT's own two, in the code (no trim).        *)
(*                                                                         *)
(* Instance shape (8 methods, 1 root):                                     *)
(*   R --invoke--> N --:new of a Function (1.13)--> L   (closure body)     *)
(*   N --:new TL-->[observed]; R --dyn TL--> L        (L is also called)   *)
(*   R --hidden invoke_in_world--> M                                       *)
(*   M --invoke--> O, retargeted to N   (O abstract, unmaterialized)       *)
(*   R --finalizer--> W        (Julia's best-effort enqueue declines: W    *)
(*                              unmaterialized, only the collector         *)
(*                              collects it)                               *)
(*   R --invoke_modify--> I    (an abstract MI the :invoke_modify names:   *)
(*                              unmaterialized, as for :invoke)            *)
(*   M --cfunction--> C        (Julia materializes it with M)              *)
(*                                                                         *)
(* compile! of R collects R, N and L (1.13's :new edge); R's scan enrolls  *)
(* M, W and I; compile! of M collects C. A collector without the          *)
(* finalizer kind never collects W                                         *)
(* (MCClosedWorldKindsCollectorKindsMissingBroken). c7f0c250's trim, whose *)
(* relation lacked A2C1's kinds, dropped L once M's retarget triggered it  *)
(* (the 1.13 drops, b107); it is deleted.                                  *)
EXTENDS ClosedWorld

MCMethods == {"R", "N", "L", "M", "O", "W", "C", "I"}
MCRoots   == {"R"}
MCTypes   == {"TL"}

MCInvokeEdges == [m \in MCMethods |->
    IF   m = "R" THEN {"N"}
    ELSE IF m = "M" THEN {"O"}
    ELSE {}]

MCRetargets == [m \in MCMethods |-> IF m = "M" THEN {<<"O", "N">>} ELSE {}]

MCTypeSites  == [m \in MCMethods |-> IF m = "N" THEN {"TL"} ELSE {}]
MCDynSites   == [m \in MCMethods |-> IF m = "R" THEN {"TL"} ELSE {}]
MCDynTargets == [t \in MCTypes |-> {"L"}]

MCSpecializeFails == {}
MCRoundCeiling    == 0
MCSwallowFailures == FALSE
MCHiddenEdges     == [m \in MCMethods |->
    IF   m = "R" THEN {<<"M", "invoke_in_world">>, <<"W", "finalizer">>, <<"I", "invoke_modify">>}
    ELSE IF m = "N" THEN {<<"L", "new_function">>}
    ELSE IF m = "M" THEN {<<"C", "cfunction">>}
    ELSE {}]
MCWidened         == {}
MCUnmaterialized  == {"O", "W", "I"}
MCCollectorKinds  == HiddenKinds
MCTrim            == FALSE
MCFmaEdges        == [m \in MCMethods |-> {}]
MCExternalLeaves  == {}
MCLateCut         == TRUE

(* the Broken variant's relation *)
MCCollectorKindsNoFinalizer == HiddenKinds \ {"finalizer"}

(* the instance uses every A2C1 kind *)
ASSUME JuliaKinds \subseteq {p[2] : p \in UNION {MCHiddenEdges[m] : m \in MCMethods}}

(* this instance's original is never materialized *)
ASSUME OriginalsUnmaterialized
=============================================================================
