---------------------------- MODULE MCFixIrreducible ----------------------------
(* Every CFG of N blocks, each with at most two successors, reachable, the  *)
(* entry with no predecessors, irreducible ones among them, fixed as LLVM's *)
(* WebAssemblyFixIrreducibleControlFlow does. Each Broken instance flips    *)
(* Bug to a realistic wrong variant and checks only the claim it breaks.    *)
EXTENDS FixIrreducible
=============================================================================
