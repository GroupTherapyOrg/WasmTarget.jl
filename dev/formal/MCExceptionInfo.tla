---------------------------- MODULE MCExceptionInfo ----------------------------
(* Every CFG of N blocks (forward edges, at most two from a block, at most  *)
(* one back edge), reachable from an entry with no predecessors, with every *)
(* set of EH pads among the other blocks, its exception tree computed as    *)
(* LLVM's WebAssemblyExceptionInfo does. N=5, the fewest blocks where a     *)
(* block is reached only through two subexceptions (the entry, the outer    *)
(* pad, two inner pads, their join), which the frontier-follow alone maps.  *)
(* Each Broken instance flips Bug to a realistic wrong variant and checks   *)
(* only the claim it breaks.                                                *)
EXTENDS ExceptionInfo
=============================================================================
