-------------------------- MODULE MCIdTable -----------------------------------
(* Julia's identity table (julia/src/iddict.c; src/julia/runtime/iddict.jl)  *)
(* over three keys, `nothing` among them, two values and tables of 2, 4 and  *)
(* 8 slots, a probe bound of 1 (so a walk wraps and a full window grows the  *)
(* table), from an image constant of two pairs laid out natively in 4 slots, *)
(* every put, pop! and rehash explored. The ids: k1 and nil share k1's home  *)
(* slot in 2 and 4 slots (a deleted k1 lies on nil's walk), k2 shares it in  *)
(* 2. Claims: LookupAgrees, OneSlotPerKey, NextindVisitsMap, CountAgrees.    *)
(* Broken: MCIdTablePopClearsKeyBroken.cfg, MCIdTableNothingStopsBroken.cfg, *)
(* MCIdTableIdsRecomputedBroken.cfg (each LookupAgrees).                     *)
EXTENDS IdTable
MCKeys == {"k1", "k2", "nil"}
MCVals == {"v1", "v2"}
MCNativeId == [k \in MCKeys |-> CASE k = "k1" -> 0 [] k = "k2" -> 2 [] k = "nil" -> 4]
\* the id a module that kept no image id would give k1: another home slot in 4
MCRecomputedId == [MCNativeId EXCEPT !["k1"] = 3]
MCInitPairs == [k \in {"k1", "k2"} |-> IF k = "k1" THEN "v1" ELSE "v2"]
=============================================================================
