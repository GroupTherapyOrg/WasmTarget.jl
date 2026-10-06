---------------------------- MODULE MCClassIdSwitch ----------------------------
(* S1, S2 and S3 are classed structs made by %new, S3 with S1's deduplicated     *)
(* layout; MR a MemoryRef (a classed struct made by memoryrefnew); M1 a          *)
(* Memory{Int64}, M2 a Memory{Any} and SV a SimpleVector, bare arrays made by    *)
(* builtins, each its own array type. mAbs's abstract parameter admits S2 and MR. *)
(* S3 has no method. The positive instance runs each method for its classes and  *)
(* traps for S3. The Broken instances: a collector that misses builtins traps    *)
(* for MR; a cast-only row runs mS1 for an S3 (its layout is S1's).              *)
EXTENDS ClassIdSwitch

MCClasses == {"S1", "S2", "S3", "MR", "M1", "M2", "SV"}
MCBare == {"M1", "M2", "SV"}
MCLayouts == {"L1", "L2", "LMR", "arrI64", "arrAnyMut", "arrAnyImm"}
MCLayout == [c \in MCClasses |->
    IF c \in {"S1", "S3"} THEN "L1" ELSE IF c = "S2" THEN "L2" ELSE IF c = "MR" THEN "LMR"
    ELSE IF c = "M1" THEN "arrI64" ELSE IF c = "M2" THEN "arrAnyMut" ELSE "arrAnyImm"]
MCByBuiltin == {"MR", "M1", "M2", "SV"}
MCMethods == {"mS1", "mAbs", "mM1", "mM2", "mSV"}
MCMOrd == [m \in MCMethods |->
    IF m = "mS1" THEN 1 ELSE IF m = "mAbs" THEN 2 ELSE IF m = "mM1" THEN 3 ELSE IF m = "mM2" THEN 4 ELSE 5]
MCParam == [m \in MCMethods |->
    IF m = "mS1" THEN {"S1"} ELSE IF m = "mAbs" THEN {"S2", "MR"} ELSE IF m = "mM1" THEN {"M1"}
    ELSE IF m = "mM2" THEN {"M2"} ELSE {"SV"}]
=============================================================================
