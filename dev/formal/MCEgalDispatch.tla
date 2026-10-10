---------------------------- MODULE MCEgalDispatch ----------------------------
(* Every order in which codegen numbers and lays out the three closure     *)
(* classes, the egal function's first use and its fill, then every static- *)
(* type pair and every pair of values it admits. Each Broken instance      *)
(* flips one flag (floats by value, Strings, immutables or closures by     *)
(* identity, the dummy context unwrapped, a mutable callable compared by   *)
(* fields, the body filled once early) and disagrees with Julia on the     *)
(* witness pair its rule breaks.                                           *)
EXTENDS EgalDispatch
=============================================================================
