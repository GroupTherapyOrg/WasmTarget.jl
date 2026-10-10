---------------------- MODULE MCClosedWorldTrimDrops ----------------------
(* TrimDrops: MCClosedWorldGarbage with c7f0c250's superseded trim (Trim  *)
(* = TRUE in the .cfg), deleted in batch 111 -- b106's F1 trace, the       *)
(* reason it is gone. X, already                                           *)
(* collected through the materialized O when the dynamic step saw it, is   *)
(* not a dynamic root; M's retarget triggers the trim, which drops O's     *)
(* subtree, X with it, and X is never proposed again.                      *)
EXTENDS MCClosedWorldGarbage
=============================================================================
