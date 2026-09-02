-------------------------- MODULE MCClassIdDispatchIsa --------------------------
(* RangeIsa over the lazily numbered classes (MaxLate = 2, same constants as    *)
(* MCClassIdDispatch): ensure_type_id! records a late id on every abstract       *)
(* ancestor's type_extra_ids, and the isa emitter tests the DFS range OR those   *)
(* extras -- also for an ancestor with no early descendant, hence no range.     *)
(* The Broken instance is the pre-fix emitter (extras only inside the has-range *)
(* branch), rejected on a 4-deep abstract chain over one late leaf.             *)
EXTENDS ClassIdDispatch
MCSelectors   == {}
MCArity       == [s \in {} |-> 1]
MCMethodSpace == {[s \in {} |-> {}]}
=============================================================================
