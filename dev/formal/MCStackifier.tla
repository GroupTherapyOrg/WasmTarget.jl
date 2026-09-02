---------------------------- MODULE MCStackifier ----------------------------
(* Correct instance (used by MCStackifier.cfg, N=4, SPECIFICATION Spec):     *)
(* L90 fully active, exhaustive over the whole N=4 class.                    *)
(*                                                                           *)
(* Broken instance (used by MCStackifierBroken.cfg, SkipCrossingNormaliz-    *)
(* ation=TRUE, SPECIFICATION WitnessSpec below): N=5/6 exhaustive is NOT     *)
(* CI-tractable (see MCStackifier.cfg's header), so this is a single FIXED   *)
(* CFG instead -- the smallest crossing-region shape found by hand-deriving *)
(* from the exhaustive N<=4 search's absence of one, then confirmed by TLC: *)
(*   block1 COND->4     (an outside guard bypassing the header, block 2)    *)
(*   block2 (header, back-edge target of block5) FALL -> block3             *)
(*   block3 GOTO->5      (continues toward the latch)                       *)
(*   block4 RET          (T=4, the shared/crossing target; phifree=FALSE so *)
(*                        duplication is INELIGIBLE -- prev=block3=GOTO so  *)
(*                        prev_can_fallthrough IS false, i.e. duplication   *)
(*                        would apply if only phifree were TRUE; this       *)
(*                        witness deliberately keeps it FALSE to force the  *)
(*                        general LIFO mechanism to be the only defense)    *)
(*   block5 GOTO->2      (the latch; back edge 5->2)                        *)
(*   block6 RET          (trailing filler; kind[N] must be RET)             *)
(* T=4 is numerically inside header(2)'s loop range (2 < 4 <= latch 5), but  *)
(* block1's direct edge to it bypasses the header, so the header does NOT   *)
(* dominate it -- a genuine crossing region: T=4 lands in outer_targets     *)
(* (opened at time 0), while the loop (opened at block2) nests INSIDE that  *)
(* still-open outer block. Confirmed by TLC: under                          *)
(* SkipCrossingNormalization=FALSE this CFG is safe (no violation, 5        *)
(* states); under TRUE (this instance) TLC finds WellScopedBr violated at   *)
(* block5's back edge (state 6 of 6) -- the labelstack/physstack divergence *)
(* traced in Stackifier.tla's header, physically closing the loop one step  *)
(* early so the eventual back-edge br targets a construct physstack proves  *)
(* is already gone.                                                        *)
EXTENDS Naturals, Sequences, FiniteSets, TLC
CONSTANT N, SkipCrossingNormalization, UseSpanCarving
VARIABLES kind, target, phifree, boundscheck, algoDead, doms, cur, pc, labelstack, physstack, emitted, wsv
INSTANCE Stackifier

WitnessInit ==
    /\ kind = <<"COND", "FALL", "GOTO", "RET", "GOTO", "RET">>
    /\ target = <<4, 1, 5, 1, 2, 1>>
    /\ phifree = <<FALSE, FALSE, FALSE, FALSE, FALSE, FALSE>>
    /\ boundscheck = <<FALSE, FALSE, FALSE, FALSE, FALSE, FALSE>>
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
