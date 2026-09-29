---------------------------- MODULE MCEgalDispatch ----------------------------
(* Every static-type pair and every pair of values it admits. The Broken  *)
(* instances compare floats by value, Strings by identity, immutables by   *)
(* identity: each disagrees with Julia on the witness pair its rule breaks. *)
EXTENDS EgalDispatch
=============================================================================
