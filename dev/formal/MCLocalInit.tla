---------------------------- MODULE MCLocalInit ----------------------------
(* Every well-nested program of at most MaxLen = 7 instructions over get   *)
(* and set of the defaultable local d and the non-defaultable local n,     *)
(* block, if, else, try, catch and end, built by every interleaving of at  *)
(* most MaxFrags = 2 open fragments appended by the replay. The Broken     *)
(* instances flip one flag each, at MaxLen = 5: NoResetAtEnd accepts       *)
(* `block; set n; end; get n` (Agrees); MergeIgnoresRequires accepts the   *)
(* fragment `get n` appended where n is unset; MergeAppliesNestedSets      *)
(* accepts the fragment `block; set n; end; get n`, whose nested set,      *)
(* replayed first, meets its own requirement (both MergeAgrees).           *)
EXTENDS LocalInit
=============================================================================
