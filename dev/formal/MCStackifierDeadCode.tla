-------------------------- MODULE MCStackifierDeadCode ----------------------
(* Broken instance for the STEP 0 dead-code mechanism (b9f4d229): the pre-  *)
(* fix "text span between an always-taken jump and its target is dead"     *)
(* rule, reintroduced via UseSpanCarving, in place of reachability.         *)
(* Exhaustive N=5 enumeration is NOT CI-tractable (see MCStackifier.cfg's   *)
(* header for the measured cost at N=4/N=5), so -- exactly as              *)
(* MCStackifierBroken.cfg does for the L90 crossing-region bug -- this is   *)
(* a single FIXED witness CFG, confirmed by TLC in <1s:                    *)
(*   block1 COND, boundscheck=TRUE, target=4  (always-jump; folds away its  *)
(*                 OWN trivial edge to block2)                              *)
(*   block2 GOTO->3                                                        *)
(*   block3 GOTO->5                                                        *)
(*   block4 GOTO->2   (T=4's landing point; jumps BACK into the span)       *)
(*   block5 RET                                                            *)
(* True reachability (over the folded RawSuccessors) finds ALL five blocks  *)
(* reachable: 1->4->2->3->5 (via block4's own back edge). The OLD span rule *)
(* instead marks {2,3} dead purely because they sit between block1 and its  *)
(* target (block4), independent of block4's own edge back into the span --  *)
(* so block4's GOTO to block2 becomes unresolvable (block2 is "dead") and   *)
(* is SILENTLY dropped (no reject: block2 was never a label target, so no   *)
(* get_loop_label/get_forward_label lookup is even attempted -- see         *)
(* ResolveJump's `t \in AlgoDeadBlocks` short-circuit in Stackifier.tla),   *)
(* while the ground-truth ledger AllOutEdges (true reachability, independent*)
(* of UseSpanCarving) still expects it. TLC confirms: pc reaches "Done"     *)
(* with emitted = {(1,4,uncond)} only, vs. AllOutEdges containing all four  *)
(* real edges -- EveryEdgeRealized violated, with NO reject in between,     *)
(* matching that the real bug (reduce(max, 1:n) on Julia 1.13) was a        *)
(* silent wrong value (returned 0), not a compile-time failure.             *)
EXTENDS Naturals, Sequences, FiniteSets, TLC
CONSTANT N, SkipCrossingNormalization, UseSpanCarving
VARIABLES kind, target, phifree, boundscheck, algoDead, doms, cur, pc, labelstack, physstack, emitted, wsv
INSTANCE Stackifier

WitnessInit ==
    /\ kind = <<"COND", "GOTO", "GOTO", "GOTO", "RET">>
    /\ target = <<4, 3, 5, 2, 1>>
    /\ phifree = <<FALSE, FALSE, FALSE, FALSE, FALSE>>
    /\ boundscheck = <<TRUE, FALSE, FALSE, FALSE, FALSE>>
    /\ algoDead = ComputeAlgoDeadBlocks
    /\ doms = ComputeDominators
    /\ cur = 1
    /\ pc = "Run"
    /\ labelstack = BlockPushSeq(OuterTargets)
    /\ physstack = BlockPushSeq(OuterTargets)
    /\ emitted = {}
    /\ wsv = FALSE

WitnessSpec == WitnessInit /\ [][Next]_vars
=============================================================================
