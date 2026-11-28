--------------------------- MODULE MCCFGStackifyEH ----------------------------
(* The stackifier over ten of Julia's try/catch CFGs (CFGStackifyEH.tla's    *)
(* Shapes, code_typed on Julia 1.12), each under every layout sortBlocks can *)
(* produce: EH pads, try_table placement, the unreachables, the call unwind  *)
(* mismatches fixed by nested try_tables and their trampolines, and depths.  *)
(* Each Broken instance flips Bug to a realistic wrong variant and checks    *)
(* only the claim it breaks.                                                 *)
EXTENDS CFGStackifyEH
=============================================================================
