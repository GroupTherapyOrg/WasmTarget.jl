--------------------------- MODULE MCClassIdDispatch ---------------------------
(* Numbering instance: every tree over 6 classes (720 shapes), every closed     *)
(* world that leaves up to 2 concrete classes to the lazy ensure_type_id! path, *)
(* no selectors.  Claims: RangesNest, Determinism.                              *)
EXTENDS ClassIdDispatch
MCSelectors   == {}
MCArity       == [s \in {} |-> 1]
MCMethodSpace == {[s \in {} |-> {}]}
=============================================================================
