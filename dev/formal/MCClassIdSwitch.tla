---------------------------- MODULE MCClassIdSwitch ----------------------------
(* S1 and S2 are classed structs made by %new; MR a MemoryRef (a classed    *)
(* struct made by memoryrefnew); M1 a Memory{Int64}, M2 a Memory{Any} and SV *)
(* a SimpleVector, bare arrays made by builtins, M2 and SV one array type.  *)
(* Every class but S2 has a specialization. The positive instance runs S1,  *)
(* MR and M1's and traps for S2 (no method) and for M2 and SV (shared). The *)
(* Broken instances: a collector that misses builtins traps for MR and M1;  *)
(* a naive bare read runs M2's specialization for an SV.                    *)
EXTENDS ClassIdSwitch

MCClasses == {"S1", "S2", "MR", "M1", "M2", "SV"}
MCBare == {"M1", "M2", "SV"}
MCTypes == {"arrI64", "arrAny"}
MCArrayType == [c \in MCBare |-> IF c = "M1" THEN "arrI64" ELSE "arrAny"]
MCByBuiltin == {"MR", "M1", "M2", "SV"}
MCOrd == [c \in MCClasses |->
    IF c = "S1" THEN 1 ELSE IF c = "S2" THEN 2 ELSE IF c = "MR" THEN 3
    ELSE IF c = "M1" THEN 4 ELSE IF c = "M2" THEN 5 ELSE 6]
MCMethods == {"mS1", "mMR", "mM1", "mM2", "mSV"}
MCParam == [m \in MCMethods |->
    IF m = "mS1" THEN "S1" ELSE IF m = "mMR" THEN "MR" ELSE IF m = "mM1" THEN "M1"
    ELSE IF m = "mM2" THEN "M2" ELSE "SV"]
=============================================================================
