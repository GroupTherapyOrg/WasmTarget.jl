------------------------ MODULE MCConstants -------------------------------
(* Model-checked instance: N=3 occurrences, 2 equality classes -- exhaustive *)
(* over the whole supported class (by pigeonhole, every reachable Init state *)
(* already has at least one forced eqclass collision among the 3            *)
(* occurrences, so canonicalization/non-aliasing are exercised in EVERY      *)
(* trace, not just some). `child[v] \in {0} \cup 1..(v-1)` lets a chain run  *)
(* v3 -> v2 -> v1, so eagerness monotonicity is checked transitively         *)
(* (grandchild spoils grandparent), not just one hop. All four bug flags are *)
(* FALSE here -- the real, unmodified funnel. *)
EXTENDS Constants

MCEqIds == {"e1", "e2"}

=============================================================================
