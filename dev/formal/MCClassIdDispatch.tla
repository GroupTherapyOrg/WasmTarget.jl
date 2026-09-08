--------------------------- MODULE MCClassIdDispatch ---------------------------
(* Numbering instance: every tree over 6 classes (720 shapes), the FULL closed  *)
(* world numbered by one DFS (Phase 12B: no more lazy ensure_type_id! path),    *)
(* no selectors.  Claims: RangesNest, RangeIsa, Determinism.  Broken            *)
(* (MCClassIdDispatchBroken.cfg, UnsortedIteration = TRUE): dfs! visits a       *)
(* node's children out of name order -- TLC must report Determinism violated.  *)
EXTENDS ClassIdDispatch
MCSelectors   == {}
MCArity       == [s \in {} |-> 1]
MCMethodSpace == {[s \in {} |-> {}]}
=============================================================================
