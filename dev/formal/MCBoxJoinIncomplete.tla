------------------------ MODULE MCBoxJoinIncomplete ------------------------
(* THE BROKEN VARIANT (item (2) of BoxJoin.tla's header -- TODAY's real     *)
(* box_capture.jl): same 3-scope chain as MCBoxJoin, but TransitiveDiscovery*)
(* = FALSE -- `_f3_capturing_closure_bodies` discovers Level1 (one hop from *)
(* Root) but never recurses into Level1's own body to find Level2 (created *)
(* and invoked from THERE, not from Root). Among the 256 initial            *)
(* configurations TLC explores, the one matching the confirmed Julia repro  *)
(* -- w_root_a = Int64T (the `x = 0` init write), w_root_b/w_level1 = None  *)
(* (level1 never writes directly, only calls level2), w_level2 = Float64T  *)
(* (the `x = 3.5` write two hops down) -- makes AlgoResult settle on the    *)
(* WRONG concrete Int64T (Level2's write is invisible to Discoverable) while*)
(* TrueWrites still contains that Float64T write: a Soundness/Completeness *)
(* violation with no reject in between, matching the "silent mutable-      *)
(* capture 0" bug class's silent-wrong-value character exactly.            *)
EXTENDS BoxJoin

MCScopes == {"Root", "Level1", "Level2"}
MCRoot   == "Root"
MCCaptures == [s \in MCScopes |->
    IF s = "Root" THEN {"Level1"}
    ELSE IF s = "Level1" THEN {"Level2"}
    ELSE {}]

MCWriteSites == {"w_root_a", "w_root_b", "w_level1", "w_level2"}
MCScopeOf == [w \in MCWriteSites |->
    IF w \in {"w_root_a", "w_root_b"} THEN "Root"
    ELSE IF w = "w_level1" THEN "Level1"
    ELSE "Level2"]

MCConcreteTypes == {"Int64T", "Float64T"}

MCTransitiveDiscovery == FALSE
MCOrderDependentJoin  == FALSE
=============================================================================
