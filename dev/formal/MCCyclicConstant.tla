------------------------- MODULE MCCyclicConstant ---------------------------
(* a cyclic constant's lazy initializer (src/constants.jl) over the Binding / *)
(* GlobalRef group, every order of its steps. Claims: Complete, NoEarlyRead,  *)
(* Valid, Ends. Broken: MCCyclicConstantEagerBroken.cfg (EagerCycle),         *)
(* Complete; MCCyclicConstantEarlyBroken.cfg (EarlyPublish), NoEarlyRead;      *)
(* MCCyclicConstantImmutableBroken.cfg (ImmutableClose), Valid.                *)
EXTENDS CyclicConstant
=============================================================================
