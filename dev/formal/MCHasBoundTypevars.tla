------------------------- MODULE MCHasBoundTypevars -------------------------
(* jl_has_typevar's walk (julia/src/jltypes.c:220 jl_has_bound_typevars)   *)
(* over every term of HasBoundTypevars's universe. Claim: Correct.           *)
(* Broken: MCHasBoundTypevarsBroken.cfg (NoShadow), Correct.                 *)
EXTENDS HasBoundTypevars
=============================================================================
