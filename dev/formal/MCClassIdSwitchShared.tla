---------------------------- MODULE MCClassIdSwitchShared ----------------------------
(* M1 a Memory{Int64} and M3 a Memory{UInt64}, one wasm array type; S1 a classed    *)
(* struct. Every class has a method, so the call's candidates include a class no     *)
(* test tells apart and the positive instance rejects it at compile time. The        *)
(* Broken instance is the rule before 2026-09-30: the shared candidates get no row,  *)
(* and a Memory{Int64} traps where Julia runs mM1.                                   *)
EXTENDS ClassIdSwitch

MCClasses == {"S1", "M1", "M3"}
MCBare == {"M1", "M3"}
MCLayouts == {"L1", "arrI64"}
MCLayout == [c \in MCClasses |-> IF c = "S1" THEN "L1" ELSE "arrI64"]
MCByBuiltin == {"M1", "M3"}
MCMethods == {"mS1", "mM1", "mM3"}
MCMOrd == [m \in MCMethods |-> IF m = "mS1" THEN 1 ELSE IF m = "mM1" THEN 2 ELSE 3]
MCParam == [m \in MCMethods |-> IF m = "mS1" THEN {"S1"} ELSE IF m = "mM1" THEN {"M1"} ELSE {"M3"}]
=============================================================================
