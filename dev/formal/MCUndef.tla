------------------------------- MODULE MCUndef -------------------------------
(* Two slots, every sequence of four operations: stores of `nothing` and of *)
(* an object, unsets, isassigned and reads.                                 *)
EXTENDS Undef
MCSlots == {"s1", "s2"}
MCSentinel == "sentinel"
MCNull == "null"
=============================================================================
