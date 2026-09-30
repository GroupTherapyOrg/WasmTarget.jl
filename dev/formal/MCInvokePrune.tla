------------------------------ MODULE MCInvokePrune ------------------------------
(* Two roots. H invokes A at two sites: s1's operands are concrete and it   *)
(* is retargeted to A2; s2's are not, so it keeps A (the subtype.jl shape). *)
(* A's body invokes B. H2 invokes C at s4, retargeted to C2: C is then      *)
(* named by no site and must go, with D below it. A2 invokes the import L.  *)
(* The positive instance (MCInvokePrune.cfg) keeps H A B A2 H2 C2; the      *)
(* Broken one (superseded pruned as leaves) drops A while s2 names it.      *)
EXTENDS InvokePrune

MCMethods == {"H", "A", "A2", "B", "H2", "C", "C2", "D", "L"}
MCRoots   == {"H", "H2"}
MCLeaves  == {"L"}
MCSites   == {"s1", "s2", "s3", "s4", "s5", "s6"}

MCHost == [s \in MCSites |->
    IF s \in {"s1", "s2"} THEN "H" ELSE IF s = "s3" THEN "A" ELSE IF s = "s4" THEN "H2"
    ELSE IF s = "s5" THEN "C" ELSE "A2"]
MCOrig == [s \in MCSites |->
    IF s \in {"s1", "s2"} THEN "A" ELSE IF s = "s3" THEN "B" ELSE IF s = "s4" THEN "C"
    ELSE IF s = "s5" THEN "D" ELSE "L"]
MCRetarget == [s \in MCSites |->
    IF s = "s1" THEN "A2" ELSE IF s = "s4" THEN "C2" ELSE "none"]
=============================================================================
