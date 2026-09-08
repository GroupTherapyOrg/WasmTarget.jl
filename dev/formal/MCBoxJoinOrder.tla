-------------------------- MODULE MCBoxJoinOrder ---------------------------
(* THE BROKEN VARIANT (a hypothetical regression of BoxJoin.tla's item (3)  *)
(* -- NOT in today's box_capture.jl, but exactly the shape a naive "fix"    *)
(* for the one-hop gap could introduce: replacing the flat-list-then-Union  *)
(* join with a worklist that just OVERWRITES a single running `contents_    *)
(* type` variable as each write is discovered, "last write wins," instead   *)
(* of folding every discovered type into a set and checking agreement).     *)
(* TransitiveDiscovery = TRUE here (so completeness is not ALSO in play --  *)
(* every write IS discoverable), isolating the violation to OrderDependent- *)
(* Join = TRUE alone: with Root writing Int64T and Level2 writing Float64T  *)
(* (both reachable), whichever write a given fold order processes LAST      *)
(* becomes the sole reported type -- order-dependent, and a direct          *)
(* Monotonicity violation (a sideways jump between two incomparable         *)
(* concrete types with no Dynamic step in between) as well as Soundness     *)
(* (the reported type contradicts whichever write was NOT last) and         *)
(* OrderIndependence (the result differs from the true two-element join).  *)
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

MCTransitiveDiscovery == TRUE
MCOrderDependentJoin  == TRUE
=============================================================================
