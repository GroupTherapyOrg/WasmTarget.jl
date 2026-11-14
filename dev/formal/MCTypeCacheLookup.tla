------------------------- MODULE MCTypeCacheLookup ---------------------------
(* The run-time lookup of apply_type's cache (src/intrinsics.jl, the          *)
(* run_time_type arm) over three operands: a literal head (one value) and two *)
(* operands of two values each, sharing a value, every entry order explored.  *)
(* Claims: Total, Agrees. Broken: MCTypeCacheLookupFirstOnlyBroken.cfg        *)
(* (Agrees) and MCTypeCacheLookupPartialBroken.cfg (Total).                   *)
EXTENDS TypeCacheLookup
MCCands == <<{"head"}, {"Int64", "Nothing"}, {"Int64", "Float64"}>>
=============================================================================
