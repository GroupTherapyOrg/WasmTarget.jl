---------------------------- MODULE MCImplicitDefs ----------------------------
(* Every CFG of N blocks FixIrreducible.tla checks, fixed by LLVM's         *)
(* FixIrreducibleControlFlow, with every register of each kind well-defined *)
(* in it, and addImplicitDefs's IMPLICIT_DEFs. Each Broken instance flips   *)
(* Bug to a realistic wrong variant and checks only the claim it breaks.    *)
EXTENDS ImplicitDefs
=============================================================================
