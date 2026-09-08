---------------------------- MODULE MCBoxJoin ------------------------------
(* The real algorithm's TARGET shape: TransitiveDiscovery = TRUE (discovery *)
(* fixed to see every depth -- what box_contents_type SHOULD do; §(2) of    *)
(* BoxJoin.tla's header is the gap between this and today's code) and       *)
(* OrderDependentJoin = FALSE (the real flat-list-then-Union join).         *)
(*                                                                          *)
(* Instance shape -- the exact 3-scope chain from the confirmed Julia repro *)
(* (BoxJoin.tla's header FINDING): Root (the box's own function, `outer`)   *)
(* creates and invokes Level1 (`level1`, ONE hop -- the shape today's       *)
(* algorithm DOES see), which itself creates and invokes Level2 (`level2`, *)
(* TWO hops -- the shape today's algorithm MISSES). Root gets TWO possible  *)
(* write slots (an enclosing scope commonly has more than one direct       *)
(* `setfield!`, e.g. an init plus a later reassignment before any closure   *)
(* runs) so claim (1)'s "ALL writes agree" is exercised within Root alone,  *)
(* not just across scopes. `Init` existentially quantifies which of the 4   *)
(* write slots exist and what each one reports (Types \cup {"None"}, 2     *)
(* concrete types -- 4 choices per slot, 4^4 = 256 initial configurations), *)
(* and TLC explores every fold order for each -- both axes the four claims  *)
(* are actually about.                                                     *)
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
MCOrderDependentJoin  == FALSE
=============================================================================
