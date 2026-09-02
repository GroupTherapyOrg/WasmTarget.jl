-------------------------- MODULE Stackifier -------------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's stackifier -- generate_stackified_flow!     *)
(* (src/codegen/stackified.jl), the algorithm that reconstructs WASM        *)
(* structured control flow (block/loop/br/br_if) from Julia IR's arbitrary  *)
(* basic-block CFG. dart2wasm never needs this pass: its Kernel IR is       *)
(* already structured, so code_generator.dart emits block/loop directly     *)
(* from visitIfStatement/visitWhileStatement/... (CodeGenerator, class      *)
(* header at code_generator.dart:28). The stackifier is a Julia-only        *)
(* necessity -- anchor: parity(quarantine: Julia IR is a CFG; dart's Kernel *)
(* is structured -- code_generator.dart visitIfStatement/visitWhileStatement).*)
(*                                                                          *)
(* WHAT THE REAL ALGORITHM DOES (the part this model checks). Blocks are    *)
(* processed once, in increasing index order. For block i the source:      *)
(*   (1) ARRIVAL-CLOSE: pops the SYMBOLIC `label_stack` entry (a `:block`   *)
(*       kind keyed by target index i, if one is open) that this block is   *)
(*       the forward-jump target of -- REQUIRING it be innermost (top of    *)
(*       stack) or throwing "crossing control regions" (stackified.jl,      *)
(*       ~line 1146-1158).                                                  *)
(*   (2) LOOP-OPEN: if i is a loop header (i.e. SOME edge i2->i has i<=i2,  *)
(*       a back edge, computed once from the whole CFG BEFORE any block is  *)
(*       walked -- ~line 357-373), opens a `:loop` label, then opens        *)
(*       `:block` labels for every forward target this loop OWNS (assigned  *)
(*       to the loop with the LARGEST header index whose [header,latch]     *)
(*       range contains the target AND which DOMINATES it -- ~line 514-594).*)
(*   (3) TERMINATOR: FALL/trivial-GOTO(i+1) realize their edge with no      *)
(*       label at all (implicit fallthrough); a real forward/back jump      *)
(*       looks its target's label UP BY IDENTITY anywhere in the open       *)
(*       stack (get_forward_label/get_loop_label, ~line 609-619) and        *)
(*       rejects ("... is not open") if absent -- this existence check is   *)
(*       what makes every successfully-emitted br well-scoped by            *)
(*       construction, matching L87 (test/parity_ratchet.jl:443): branches  *)
(*       carry symbolic ControlLabel identity, never a numeric depth.       *)
(*   (4) END-OF-LOOP: at the block that is the MAXIMAL back-edge source     *)
(*       into some header (several `continue`-style latches share one       *)
(*       header; only the last one closes it, ~line 1599-1632), closes any  *)
(*       still-open inner-target labels for that loop (each again LIFO-     *)
(*       checked, ~line 1606-1621, gracefully skipping a target already     *)
(*       closed by its own arrival), THEN unconditionally emits the loop's  *)
(*       physical `end` (end_block!(b) at line 1623, called BEFORE the      *)
(*       label_stack lookup/check that follows it) and only THEN removes    *)
(*       the symbolic `:loop` bookkeeping entry if the LIFO check passes    *)
(*       (line 1624-1630) -- this ORDERING ASYMMETRY (physical close always *)
(*       fires; symbolic close is conditional) is exactly what the Broken   *)
(*       instance below exploits.                                          *)
(*                                                                          *)
(* L90 (test/parity_ratchet.jl:493) is the "normalized or rejected" claim:  *)
(* a target block that is BOTH reachable from inside a loop's numeric range *)
(* AND from an outside predecessor the header does not dominate (a          *)
(* "crossing region") is either (a) removed from the labeling machinery     *)
(* entirely by tail-duplicating it at every use site -- ONLY when it is a   *)
(* terminal (bare ReturnNode), phi-free block with NO fallthrough           *)
(* predecessor (duplicated_terminal_targets, ~line 493-512) -- or (b), for  *)
(* every other crossing shape, caught by the LIFO checks in (1)/(4) above   *)
(* and turned into a compile-time REJECT rather than silently-wrong bytes.  *)
(*                                                                          *)
(* STEP 0 / DEAD CODE (commit b9f4d229, "dead code is what the folded CFG   *)
(* cannot reach"). An explicit `boundscheck false` (inside @inbounds)       *)
(* feeding a GotoIfNot always jumps; STEP 0 folds that branch to keep only  *)
(* its target edge (~line 137-166, 202-243). `dead_blocks` is then computed *)
(* by BFS REACHABILITY from block 1 over that folded successor graph        *)
(* (~line 261-283), BEFORE dominators/loop-ownership run, and every dead    *)
(* block's edges are stripped from successors/predecessors. formal(dev/    *)
(* formal/Stackifier.tla): every edge of the folded CFG is realized exactly *)
(* once; a block is dropped only when no path from the entry reaches it.    *)
(* The PRIOR mechanism (pinned by L89 until this fix) instead carved every  *)
(* STATEMENT between the always-jump and its target as dead code by TEXT    *)
(* POSITION, independent of reachability, and forwarded orphaned edges      *)
(* through `resolve_through_dead_boundscheck` (now deleted). That was a     *)
(* real miscompile: on Julia 1.13, `reduce(max, 1:n)` inlines a pairwise    *)
(* loop whose header sits inside such a span but is entered by a SEPARATE,  *)
(* genuinely-reachable edge from earlier code -- the span carving marked it *)
(* dead anyway, `resolve_through_dead_boundscheck` could not forward a real *)
(* loop header (only a further boundscheck-erased block), so the incoming   *)
(* edge was silently dropped and the function returned an unset local (0).  *)
(* `UseSpanCarving` (the Broken instance) reintroduces exactly this: dead   *)
(* blocks are the TEXT SPAN between an always-taken jump and its target,    *)
(* not a reachability fixpoint -- TLC must find a CFG where this drops a    *)
(* block that a SEPARATE edge still reaches (an EveryEdgeRealized           *)
(* violation with no reject in between, matching the real bug's silent-     *)
(* wrong-value character, not a compile-time failure).                     *)
(*                                                                          *)
(* WHAT THIS MODEL ABSTRACTS, AND WHY THAT IS SUFFICIENT.                   *)
(*  - Values, phi nodes, and locals are erased entirely. The claims under   *)
(*    test (WellScopedBr/Balanced/EveryEdgeRealized/RejectNeverEmits) are   *)
(*    about CONTROL structure, not data; `set_phi_locals_for_edge!` never   *)
(*    changes the label stack or which edges exist. The one place phi-      *)
(*    ness matters to CONTROL is duplication eligibility ("terminal &&      *)
(*    phi_free"), which is a per-block VALUE-domain fact independent of     *)
(*    the CFG skeleton -- modeled as one free boolean `phifree[i]`,         *)
(*    meaningful only when kind[i]="RET", so TLC explores both the          *)
(*    "duplication applies" and "duplication does not apply" arms for       *)
(*    every eligible shape.                                                *)
(*  - The boundscheck fold and reachability-based dead-block computation    *)
(*    ARE modeled (`boundscheck[i]`, `RawSuccessors`/`TrueDeadBlocks`/      *)
(*    `AlgoDeadBlocks` below) -- this is the L89 mechanism as of b9f4d229.  *)
(*    try/catch regions (Slice B: try_open_at/try_close_at, :landing/:try   *)
(*    label kinds) are NOT re-modeled: they add two more label kinds and a  *)
(*    THIRD, separate LIFO discipline layered on the same label_stack;      *)
(*    omitting them keeps this model to the :block/:loop core L90/L89 are   *)
(*    about, per MODEL_RULES.md's "if the source's decision procedure has  *)
(*    a case you cannot map, say so."                                      *)
(*  - Function entry is always block 1; the function's last block (N) is   *)
(*    always Core.ReturnNode (kind="RET"), matching that Julia IR always    *)
(*    ends in a terminator and this model does not need a non-terminating  *)
(*    function to state any of the five claims.                            *)
(*  - `target[i]` is UNCONSTRAINED (fixed to a placeholder) when kind[i] is *)
(*    FALL/RET, `phifree[i]` is fixed to FALSE when kind[i] # RET, and      *)
(*    `boundscheck[i]` is fixed to FALSE when kind[i] # COND -- all three   *)
(*    are real degrees of freedom the source has (a GotoIfNot always HAS a  *)
(*    dest; a ReturnNode always has the phi-free fact; a GotoIfNot always   *)
(*    has the boundscheck-fold fact) that are simply irrelevant to other    *)
(*    block kinds, so leaving them free would only bloat TLC's enumeration  *)
(*    with semantically-identical CFGs.                                    *)
(*                                                                          *)
(* THE PHYSICAL/SYMBOLIC SPLIT. The real builder (InstrBuilder) has its own *)
(* genuinely-LIFO physical nesting (`end_block!` always closes whatever     *)
(* construct is CURRENTLY innermost, unconditionally -- it has no idea      *)
(* which symbolic target the caller THINKS it is closing). The algorithm's  *)
(* only defense against closing the wrong physical construct is the LIFO    *)
(* assertion in (1)/(4) above: reject rather than let a non-innermost close *)
(* proceed. This model tracks the physical nesting as a SEPARATE ground-    *)
(* truth stack `physstack` (always popped from its true top on every close  *)
(* event, matching end_block!) alongside the algorithm's own symbolic       *)
(* `labelstack` bookkeeping (search-and-remove by (kind,target) identity,   *)
(* matching label_stack). In the real (non-broken) algorithm the LIFO       *)
(* assertion keeps them in lockstep always. `SkipCrossingNormalization`     *)
(* (the Broken instance) disables BOTH halves of L90 at once -- forces      *)
(* duplication to never apply, and removes the LIFO assertion at (1)/(4),  *)
(* letting a non-innermost symbolic close proceed anyway ("pre-L90"         *)
(* behavior) -- which lets `labelstack` and `physstack` diverge: the        *)
(* algorithm can believe (per its own now-wrong bookkeeping) that a label   *)
(* is still open and branch to it, when `physstack` proves it is not.       *)
(* `WellScopedBr` is checked against `physstack` (ground truth), which is   *)
(* exactly what makes it able to catch what the algorithm's own belief      *)
(* cannot.                                                                  *)
(*                                                                          *)
(* Like SchedulerWake.tla, every action below is atomic; there is no real   *)
(* concurrency here (generate_stackified_flow! is single-threaded/          *)
(* sequential) -- TLC's exploration is over the INITIAL CHOICE of CFG       *)
(* shape (kind/target/phifree, chosen once in Init, unconstrained within    *)
(* the supported class), not over interleavings. Each choice then runs a   *)
(* single deterministic trace; TLC checking every initial choice is what    *)
(* "enumerates edge relations."                                            *)
(*                                                                          *)
(* formal(src/codegen/stackified.jl generate_stackified_flow): every        *)
(* forward/back branch the stackifier emits targets a label that is        *)
(* PHYSICALLY open at the point of emission, and a CFG shape the general    *)
(* mechanism (post tail-duplication) cannot realize this way is REJECTED   *)
(* at compile time rather than silently mis-scoped; separately (STEP 0),   *)
(* every edge of the folded CFG is realized exactly once and a block is    *)
(* dropped only when no path from the entry reaches it.                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    N,                          \* number of basic blocks, indexed 1..N
    SkipCrossingNormalization,  \* BOOLEAN: TRUE = the Broken (pre-L90) variant
    UseSpanCarving              \* BOOLEAN: TRUE = the Broken (pre-b9f4d229) dead-code variant

ASSUME N \in Nat /\ N >= 2
ASSUME SkipCrossingNormalization \in BOOLEAN
ASSUME UseSpanCarving \in BOOLEAN

Blocks == 1..N
Kinds == {"FALL", "RET", "GOTO", "COND"}
Dirs == {"true", "false", "uncond"}
LabelKinds == {"block", "loop"}
LabelEntry == [k: LabelKinds, t: Blocks]
EdgeRec == [src: Blocks, dst: Blocks, dir: Dirs]

VARIABLES
    kind,        \* [Blocks -> Kinds] -- chosen once at Init, then fixed
    target,      \* [Blocks -> Blocks] -- meaningful only where kind requires it
    phifree,     \* [Blocks -> BOOLEAN] -- meaningful only where kind = "RET"
    boundscheck, \* [Blocks -> BOOLEAN] -- meaningful only where kind = "COND";
                 \* TRUE = this GotoIfNot is an always-taken `boundscheck false` fold
    algoDead,    \* SUBSET Blocks -- CACHE of ComputeAlgoDeadBlocks, frozen at Init
    doms,        \* [Blocks -> SUBSET Blocks] -- CACHE of ComputeDominators, frozen at Init
    cur,         \* the block currently being (or about to be) processed
    pc,          \* "Run" | "FinalSweep" | "Done" | "Reject"
    labelstack,  \* Seq(LabelEntry) -- the algorithm's OWN symbolic bookkeeping
    physstack,   \* Seq(LabelEntry) -- ground-truth physical builder nesting
    emitted,     \* SUBSET EdgeRec -- edges realized (br/br_if/fallthrough/inline) so far
    wsv          \* BOOLEAN -- "a well-scoped-branch violation has occurred"

vars == <<kind, target, phifree, boundscheck, algoDead, doms, cur, pc, labelstack, physstack, emitted, wsv>>

----------------------------------------------------------------------------
(* Derived CFG structure -- pure functions of kind/target/boundscheck,      *)
(* which never change after Init. Mirrors stackified.jl STEP 0-STEP 6.      *)

\* A boundscheck-folded COND behaves like a GOTO for every purpose EXCEPT
\* its own terminator-processing arm (BoundscheckTerminator below, which
\* lacks a back-edge case -- stackified.jl ~line 1307-1315).
EffectiveKind(i) == IF kind[i] = "COND" /\ boundscheck[i] THEN "GOTO" ELSE kind[i]

\* RawSuccessors(i): the folded-but-unfiltered edges STEP 1 builds
\* (~line 202-243) -- the boundscheck fold applied, no dead-block filtering
\* yet (dead_blocks does not exist at this point in the source).
RawSuccessors(i) ==
    CASE kind[i] = "FALL" -> {i + 1}
      [] kind[i] = "RET"  -> {}
      [] EffectiveKind(i) = "GOTO" -> {target[i]}
      [] OTHER -> {i + 1, target[i]}   \* kind[i] = "COND" /\ ~boundscheck[i]

\* Reachability from the entry (block 1) over RawSuccessors -- exactly the
\* BFS at ~line 261-283, computed BEFORE any notion of "dead" exists. This
\* is GROUND TRUTH, independent of UseSpanCarving.
RECURSIVE ReachFrom(_, _)
ReachFrom(frontier, seen) ==
    IF frontier = {} THEN seen
    ELSE LET new == UNION {RawSuccessors(i) : i \in frontier} \ seen
         IN ReachFrom(new, seen \union frontier)

TrueReached == ReachFrom({1}, {})
TrueDeadBlocks == Blocks \ TrueReached

\* The mechanism b9f4d229 DELETED: every statement (here, every BLOCK)
\* strictly between an always-taken boundscheck jump and its target was
\* dead code by TEXT POSITION, regardless of whether some other edge still
\* reaches it (~line 137-166 pre-fix). Reintroduced only under
\* UseSpanCarving.
OldSpanDeadBlocks ==
    UNION {{j \in Blocks : i < j /\ j < target[i]} :
             i \in {ii \in Blocks : kind[ii] = "COND" /\ boundscheck[ii]}}

\* ComputeAlgoDeadBlocks: the algorithm's OWN belief about which blocks are
\* dead -- correct (reachability) unless UseSpanCarving forces the old,
\* unsound text-span mechanism. Everything below this point mirrors
\* stackified.jl operating on `dead_blocks`, whichever way it was computed.
\* PERFORMANCE: kind/target/boundscheck never change after Init (every
\* action is UNCHANGED on them), so this -- and ComputeDominators below,
\* which is far more expensive -- is a CONSTANT for the whole trace once
\* chosen. Recomputing either one from scratch at every one of their many
\* reference sites (Successors alone is called ~N times per Pred, ~N^2
\* times per Dominators fixpoint round) makes TLC superlinear in N for no
\* reason. Both are computed EXACTLY ONCE, in Init, into the cached
\* variables `algoDead`/`doms`; `AlgoDeadBlocks`/`Dominators` below are
\* then plain O(1) reads of that cache, safe to reference freely.
AlgoDeadBlocks == algoDead
ComputeAlgoDeadBlocks == IF UseSpanCarving THEN OldSpanDeadBlocks ELSE TrueDeadBlocks

\* Successors(i): RawSuccessors filtered through the algorithm's belief --
\* dead blocks contribute no edges and are never a live target (~line
\* 272-282's `filter!`).
Successors(i) == IF i \in AlgoDeadBlocks THEN {}
                  ELSE {s \in RawSuccessors(i) : s \notin AlgoDeadBlocks}

Pred(j) == {i \in Blocks : j \in Successors(i)}

\* Every LOGICAL out-edge of block i as a distinct, directed record (a COND
\* contributes two records even when both arms coincide on the same dst --
\* matching that GotoIfNot always consumes/dispatches on its condition; a
\* boundscheck fold contributes exactly the one edge STEP 0 keeps).
OutEdges(i) ==
    CASE kind[i] = "FALL" -> {[src |-> i, dst |-> i + 1, dir |-> "uncond"]}
      [] kind[i] = "RET"  -> {}
      [] EffectiveKind(i) = "GOTO" -> {[src |-> i, dst |-> target[i], dir |-> "uncond"]}
      [] OTHER -> {[src |-> i, dst |-> i + 1, dir |-> "true"],
                    [src |-> i, dst |-> target[i], dir |-> "false"]}

\* GROUND TRUTH for EveryEdgeRealized: every edge of every block the entry
\* can TRULY reach -- independent of AlgoDeadBlocks, so a block the
\* algorithm wrongly believes dead (UseSpanCarving) still owes its edges.
AllOutEdges == UNION {OutEdges(i) : i \in Blocks \ TrueDeadBlocks}

\* STEP 2: back edges / loop headers -- computed from the (algorithm's own,
\* dead-filtered) CFG, once, before any block is walked (~line 360-373 —
\* now after the STEP-0/dead-block pass, matching source's ordering).
BackEdges == {<<i, j>> \in Blocks \X Blocks : j \in Successors(i) /\ j <= i}
LoopHeaders == {j \in Blocks : \E i \in Blocks : <<i, j>> \in BackEdges}

\* loop_latches: the MAXIMAL back-edge source into header h (line 522-528).
LatchSet(h) == {i \in Blocks : <<i, h>> \in BackEdges}
Latch(h) == IF LatchSet(h) = {} THEN 0
            ELSE CHOOSE m \in LatchSet(h) : \A o \in LatchSet(h) : m >= o

\* STEP: dominators via the same iterative dataflow as stackified.jl
\* (~line 322-354): block 1 dominates itself only; every other live block's
\* dominator set is itself union the intersection of its predecessors'
\* dominator sets. N rounds is always enough to reach the fixpoint for an
\* N-block CFG (standard dataflow convergence bound).
IntersectAll(SS) == {x \in UNION SS : \A s \in SS : x \in s}

DomUpdate(dom) ==
    [i \in Blocks |->
        IF i = 1 THEN {1}
        ELSE LET preds == Pred(i)
             IN IF preds = {} THEN {i}
                ELSE {i} \union IntersectAll({dom[p] : p \in preds})]

RECURSIVE DomIter(_, _)
DomIter(dom, k) == IF k = 0 THEN dom ELSE DomIter(DomUpdate(dom), k - 1)

\* Cached (see the PERFORMANCE note above AlgoDeadBlocks): computed once
\* into `doms` at Init, read back here as an O(1) lookup everywhere else.
Dominators == doms
ComputeDominators == DomIter([i \in Blocks |-> Blocks], N)

\* STEP 3/duplication: non_trivial_targets (line 405-437) -- every non-
\* fallthrough jump-arm destination (GOTO's target, or COND's dest/false
\* arm, boundscheck-folded or not; COND's true/fallthrough arm is NEVER a
\* target here) from a LIVE source, landing on a LIVE destination -- a dead
\* source is skipped outright (line 407-410) and a dead destination is
\* excluded (the `!(dest_block in dead_blocks)` guard at every arm).
NonTrivialTargets ==
    {target[i] : i \in {ii \in Blocks : ii \notin AlgoDeadBlocks
                          /\ kind[ii] \in {"GOTO", "COND"} /\ target[ii] # ii + 1
                          /\ target[ii] \notin AlgoDeadBlocks}}

\* duplicated_terminal_targets (line 485-512): terminal && phi_free && the
\* physically-preceding block (target-1) neither falls through nor is dead
\* -- i.e. it is itself GOTO or RET (prev_can_fallthrough = FALSE).
PrevCanFallthrough(t) == IF t = 1 THEN TRUE ELSE kind[t - 1] \notin {"GOTO", "RET"}

DupCandidate(t) ==
    /\ kind[t] = "RET"
    /\ phifree[t]
    /\ t \in NonTrivialTargets
    /\ ~PrevCanFallthrough(t)

DuplicatedTerminalTargets == IF SkipCrossingNormalization THEN {}
                              ELSE {t \in Blocks : DupCandidate(t)}

RemainingNonTrivial == NonTrivialTargets \ DuplicatedTerminalTargets

\* target_loop assignment (line 514-594): a remaining target belongs to the
\* loop with the LARGEST header among those whose (header,latch] range
\* contains it AND which DOMINATE it; otherwise it is an outer target.
TargetLoopCandidates(t) ==
    {h \in LoopHeaders : t > h /\ Latch(h) # 0 /\ t <= Latch(h) /\ h \in Dominators[t]}

TargetLoop(t) == IF TargetLoopCandidates(t) = {} THEN 0
                  ELSE CHOOSE h \in TargetLoopCandidates(t) :
                          \A h2 \in TargetLoopCandidates(t) : h >= h2

OuterTargets == {t \in RemainingNonTrivial : TargetLoop(t) = 0}
LoopInnerTargets(h) == {t \in RemainingNonTrivial : TargetLoop(t) = h}

\* Descending sequence of a finite Nat set (largest first) -- matches
\* `sort!(...; rev=true)` at both the OPEN site and the (line 1610) CLOSE
\* site for a loop's inner targets, and at the outer_targets open (line 583).
RECURSIVE SeqDesc(_)
SeqDesc(S) == IF S = {} THEN <<>>
              ELSE LET m == CHOOSE x \in S : \A y \in S : x >= y
                   IN <<m>> \o SeqDesc(S \ {m})

BlockPushSeq(S) == [i \in 1..Len(SeqDesc(S)) |-> [k |-> "block", t |-> SeqDesc(S)[i]]]

----------------------------------------------------------------------------
(* The label-stack machinery: symbolic (labelstack) vs. physical           *)
(* (physstack) closes, threaded through a small record so a whole block's  *)
(* processing (1)-(4) can short-circuit to Reject partway through exactly  *)
(* like a thrown Julia exception aborting the rest of the function.        *)

RemoveAt(seq, i) == SubSeq(seq, 1, i - 1) \o SubSeq(seq, i + 1, Len(seq))

StepState == [ls: Seq(LabelEntry), ps: Seq(LabelEntry), em: SUBSET EdgeRec,
               wsv: BOOLEAN, ok: BOOLEAN]

\* CloseTarget: the (1)/(4)-inner-target close pattern -- physical pop
\* happens ONLY together with a found+accepted symbolic removal (matches
\* stackified.jl's `_lb === nothing && break` / the inner-target loop at
\* line 1610-1620, where end_block! is inside the `if _it !== nothing`).
CloseTarget(st, key) ==
    IF ~st.ok THEN st
    ELSE LET idxs == {i \in 1..Len(st.ls) : st.ls[i] = key}
         IN IF idxs = {} THEN st
            ELSE LET pos == CHOOSE i \in idxs : TRUE
                     innermost == (pos = Len(st.ls))
                 IN IF SkipCrossingNormalization \/ innermost
                    THEN [st EXCEPT !.ls = RemoveAt(st.ls, pos),
                                    !.ps = RemoveAt(st.ps, Len(st.ps))]
                    ELSE [st EXCEPT !.ok = FALSE]

RECURSIVE FoldCloseBlocks(_, _)
FoldCloseBlocks(st, seq) ==
    IF seq = <<>> THEN st
    ELSE FoldCloseBlocks(CloseTarget(st, [k |-> "block", t |-> Head(seq)]), Tail(seq))

ArrivalClose(st, c) == CloseTarget(st, [k |-> "block", t |-> c])

LoopOpen(st, c) ==
    IF ~st.ok THEN st
    ELSE IF c \notin LoopHeaders THEN st
         ELSE LET afterLoop == [st EXCEPT !.ls = Append(st.ls, [k |-> "loop", t |-> c]),
                                           !.ps = Append(st.ps, [k |-> "loop", t |-> c])]
                  pushed == BlockPushSeq(LoopInnerTargets(c))
              IN [afterLoop EXCEPT !.ls = @ \o pushed, !.ps = @ \o pushed]

\* ResolveJump: a GOTO's target, or a COND's false/dest arm (line 1374-1561).
\* A target the algorithm believes DEAD is UNRESOLVABLE and the branch is
\* silently dropped, exactly like the deleted resolve_through_dead_
\* boundscheck failing to forward a real (non-erasure-shaped) block and
\* `dest_block` coming back `nothing` (the old "unresolvable dest: drop the
\* compiled condition rather than orphaning it" path) -- this is the SOLE
\* mechanism by which UseSpanCarving can drop a genuinely-reachable block's
\* edges with NO reject in between. Otherwise: duplication or a literal
\* trivial next-block jump realize the edge with NO label lookup at all;
\* else look the target up BY IDENTITY anywhere in labelstack
\* (get_forward_label/get_loop_label, line 609-619) -- absent there means
\* the algorithm itself rejects ("... is not open"); present in labelstack
\* but ABSENT from physstack is exactly a well-scoped-branch violation the
\* algorithm's own bookkeeping cannot see.
ResolveJump(st, c, t, dir) ==
    IF ~st.ok THEN st
    ELSE IF t \in AlgoDeadBlocks THEN st
         ELSE IF (t \in DuplicatedTerminalTargets) \/ (t = c + 1)
         THEN [st EXCEPT !.em = @ \union {[src |-> c, dst |-> t, dir |-> dir]}]
         ELSE LET key == IF t <= c THEN [k |-> "loop", t |-> t] ELSE [k |-> "block", t |-> t]
                  openInLS == \E i \in 1..Len(st.ls) : st.ls[i] = key
                  openInPS == \E i \in 1..Len(st.ps) : st.ps[i] = key
              IN IF ~openInLS THEN [st EXCEPT !.ok = FALSE]
                 ELSE [st EXCEPT !.em = @ \union {[src |-> c, dst |-> t, dir |-> dir]},
                                  !.wsv = @ \/ ~openInPS]

\* BoundscheckTerminator: the always-jump arm (line 1307-1315). Duplication
\* realizes the edge unconditionally (no label lookup); a dead target is
\* silently unresolvable exactly like ResolveJump; otherwise ONLY a
\* forward, non-trivial target is looked up (get_forward_label) -- unlike
\* ResolveJump, this branch has NO back-edge/get_loop_label arm at all, so
\* a `t <= c` target (never observed from a real boundscheck fold, which
\* always skips FORWARD to a later merge point) falls through emitting
\* NOTHING, faithfully mirroring the source's narrower always-jump case.
BoundscheckTerminator(st, c) ==
    IF ~st.ok THEN st
    ELSE LET t == target[c]
         IN IF t \in AlgoDeadBlocks THEN st
            ELSE IF (t \in DuplicatedTerminalTargets) \/ (t = c + 1)
            THEN [st EXCEPT !.em = @ \union {[src |-> c, dst |-> t, dir |-> "uncond"]}]
            ELSE IF t > c
                 THEN LET key == [k |-> "block", t |-> t]
                          openInLS == \E i \in 1..Len(st.ls) : st.ls[i] = key
                          openInPS == \E i \in 1..Len(st.ps) : st.ps[i] = key
                      IN IF ~openInLS THEN [st EXCEPT !.ok = FALSE]
                         ELSE [st EXCEPT !.em = @ \union {[src |-> c, dst |-> t, dir |-> "uncond"]},
                                          !.wsv = @ \/ ~openInPS]
                 ELSE st   \* t <= c: the source emits nothing here (no loop-label arm)

Terminator(st, c) ==
    IF ~st.ok THEN st
    ELSE IF kind[c] = "FALL" THEN
                [st EXCEPT !.em = @ \union {[src |-> c, dst |-> c + 1, dir |-> "uncond"]}]
    ELSE IF kind[c] = "RET" THEN st
    ELSE IF kind[c] = "GOTO" THEN ResolveJump(st, c, target[c], "uncond")
    ELSE IF boundscheck[c] THEN BoundscheckTerminator(st, c)   \* kind[c] = "COND"
    ELSE LET st2 == [st EXCEPT !.em = @ \union {[src |-> c, dst |-> c + 1, dir |-> "true"]}]
         IN ResolveJump(st2, c, target[c], "false")

\* CloseLoopLabel: the loop's OWN close (line 1599-1632). The PHYSICAL pop
\* is unconditional -- end_block!(b) at line 1623 fires BEFORE the
\* label_stack lookup/check that follows it -- while the symbolic removal
\* stays conditional (found + LIFO-checked). This asymmetry is the
\* mechanism the Broken instance exploits: a wrongly-early physical pop at
\* an earlier CloseTarget can leave physstack's true top no longer matching
\* what labelstack still believes is the loop, so THIS unconditional pop
\* then closes the WRONG physical construct.
CloseLoopLabel(st, h) ==
    IF ~st.ok THEN st
    ELSE LET poppedPs == RemoveAt(st.ps, Len(st.ps))
             idxs == {i \in 1..Len(st.ls) : st.ls[i] = [k |-> "loop", t |-> h]}
         IN IF idxs = {} THEN [st EXCEPT !.ps = poppedPs]
            ELSE LET pos == CHOOSE i \in idxs : TRUE
                     innermost == (pos = Len(st.ls))
                 IN IF SkipCrossingNormalization \/ innermost
                    THEN [st EXCEPT !.ls = RemoveAt(st.ls, pos), !.ps = poppedPs]
                    ELSE [st EXCEPT !.ok = FALSE, !.ps = poppedPs]

EndOfLoopClose(st, c) ==
    IF ~st.ok THEN st
    ELSE IF kind[c] \notin {"GOTO", "COND"} \/ target[c] > c \/ Latch(target[c]) # c THEN st
         ELSE LET h == target[c]
              IN CloseLoopLabel(FoldCloseBlocks(st, SeqDesc(LoopInnerTargets(h))), h)

FinalCloseAllBlocks(st) ==
    LET remaining == SeqDesc({st.ls[i].t : i \in {j \in 1..Len(st.ls) : st.ls[j].k = "block"}})
    IN FoldCloseBlocks(st, remaining)

----------------------------------------------------------------------------
(* Init: choose one CFG (kind/target/phifree) from the supported class,     *)
(* unconstrained within it -- this existential is what TLC "enumerates".   *)
(* target/phifree are pinned to a placeholder wherever the real algorithm  *)
(* never looks at them, so TLC does not waste states on semantically-      *)
(* identical duplicates. outer_targets open here (line 603-607), BEFORE    *)
(* any block is walked -- matching that they are opened right after the    *)
(* root entry_calls, ahead of the main per-block loop.                      *)

Init ==
    /\ kind \in {f \in [Blocks -> Kinds] : f[N] = "RET"}
    /\ target \in {g \in [Blocks -> Blocks] :
                     \A i \in Blocks : kind[i] \notin {"GOTO", "COND"} => g[i] = 1}
    /\ phifree \in {p \in [Blocks -> BOOLEAN] : \A i \in Blocks : kind[i] # "RET" => p[i] = FALSE}
    /\ boundscheck \in {q \in [Blocks -> BOOLEAN] : \A i \in Blocks : kind[i] # "COND" => q[i] = FALSE}
    \* An always-taken `boundscheck false` jump exists to skip FORWARD past
    \* dead check-and-throw code to a later continuation (that is what
    \* makes it "always-taken" rather than a real branch) -- a backward
    \* target is not a shape STEP 0's fold is meant for. Restricting to
    \* this real invariant is DELIBERATE, not an oversight: without it TLC
    \* finds target[i] <= i /\ boundscheck[i] as its OWN, SEPARATE
    \* EveryEdgeRealized counterexample (line 1307-1315's always-jump arm
    \* has no back-edge/get_loop_label case at all, unlike ResolveJump) --
    \* a real gap in the current algorithm, reported alongside this model
    \* but believed unreachable from real Julia IR for the reason above.
    /\ \A i \in Blocks : boundscheck[i] => target[i] > i
    \* Freeze the two expensive fixpoints (see the PERFORMANCE note above
    \* AlgoDeadBlocks) exactly once, now that kind/target/boundscheck are
    \* fixed -- everything below reads algoDead/doms, never recomputes.
    /\ algoDead = ComputeAlgoDeadBlocks
    /\ doms = ComputeDominators
    /\ cur = 1
    /\ pc = "Run"
    /\ labelstack = BlockPushSeq(OuterTargets)
    /\ physstack = BlockPushSeq(OuterTargets)
    /\ emitted = {}
    /\ wsv = FALSE

----------------------------------------------------------------------------
(* Next: one atomic action per block (1)-(4) fused together exactly as the  *)
(* real per-block loop body runs them sequentially with no observable       *)
(* intermediate step; a final sweep (line 1635-1645, structurally always a *)
(* no-op in this model's supported class -- see header); Done/Reject are   *)
(* explicit stutter states so TLC's deadlock check only fires on a genuine *)
(* stuck state. *)

\* A dead block (per the algorithm's OWN, possibly-wrong belief) or a
\* duplicated-terminal target skips loop-open/terminator/end-of-loop
\* entirely (`continue`, line 1160-1170) -- only its arrival-close (already
\* folded into s1) ever runs.
ProcessBlock(c) ==
    /\ pc = "Run"
    /\ cur = c
    /\ LET s0 == [ls |-> labelstack, ps |-> physstack, em |-> emitted, wsv |-> wsv, ok |-> TRUE]
           s1 == ArrivalClose(s0, c)
           s4 == IF (c \in AlgoDeadBlocks) \/ (c \in DuplicatedTerminalTargets)
                 THEN s1
                 ELSE EndOfLoopClose(Terminator(LoopOpen(s1, c), c), c)
       IN /\ labelstack' = s4.ls
          /\ physstack' = s4.ps
          /\ emitted' = s4.em
          /\ wsv' = s4.wsv
          /\ IF s4.ok
             THEN /\ pc' = IF c = N THEN "FinalSweep" ELSE "Run"
                  /\ cur' = IF c = N THEN c ELSE c + 1
             ELSE /\ pc' = "Reject"
                  /\ cur' = c
    /\ UNCHANGED <<kind, target, phifree, boundscheck, algoDead, doms>>

FinalSweepAction ==
    /\ pc = "FinalSweep"
    /\ LET s0 == [ls |-> labelstack, ps |-> physstack, em |-> emitted, wsv |-> wsv, ok |-> TRUE]
           s1 == FinalCloseAllBlocks(s0)
       IN /\ labelstack' = s1.ls
          /\ physstack' = s1.ps
          /\ emitted' = s1.em
          /\ wsv' = s1.wsv
          /\ pc' = IF s1.ok THEN "Done" ELSE "Reject"
          /\ cur' = cur
    /\ UNCHANGED <<kind, target, phifree, boundscheck, algoDead, doms>>

Terminal == pc \in {"Done", "Reject"} /\ UNCHANGED vars

Next == (\E c \in Blocks : ProcessBlock(c)) \/ FinalSweepAction \/ Terminal

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* The five claims. *)

TypeOK ==
    /\ kind \in [Blocks -> Kinds]
    /\ target \in [Blocks -> Blocks]
    /\ phifree \in [Blocks -> BOOLEAN]
    /\ boundscheck \in [Blocks -> BOOLEAN]
    /\ algoDead \subseteq Blocks
    /\ doms \in [Blocks -> SUBSET Blocks]
    /\ cur \in Blocks
    /\ pc \in {"Run", "FinalSweep", "Done", "Reject"}
    /\ labelstack \in Seq(LabelEntry)
    /\ physstack \in Seq(LabelEntry)
    /\ emitted \subseteq EdgeRec
    /\ wsv \in BOOLEAN

\* (1) Every branch the algorithm ever emitted targeted a label that was
\* PHYSICALLY open (present in physstack) at the moment of emission --
\* checked continuously via `wsv`, set the instant ResolveJump finds a
\* labelstack/physstack mismatch.
WellScopedBr == ~wsv

\* (2) At normal completion, every opened region was closed exactly once:
\* both the symbolic and the (ground-truth) physical stack are empty.
Balanced == pc = "Done" => (labelstack = <<>> /\ physstack = <<>>)

\* (3) At normal completion, the multiset^ of realized edges is EXACTLY the
\* CFG's edge set -- no edge dropped, none duplicated. (^ EdgeRec already
\* disambiguates a COND's coincident true/false arms by `dir`, so set
\* equality here is the right notion of "exactly once each".) `AllOutEdges`
\* is GROUND TRUTH (true reachability, independent of AlgoDeadBlocks), so
\* this is also exactly the "a block is dropped only when no path from the
\* entry reaches it" claim: a block AlgoDeadBlocks wrongly excludes (only
\* possible under UseSpanCarving) contributes no edges to `emitted`, so its
\* missing edges show up here as a violation with pc = "Done" -- no reject
\* in between, matching the real bug's silent-wrong-value character.
EveryEdgeRealized == pc = "Done" => emitted = AllOutEdges

\* (4) Once the algorithm rejects, it is done -- no further label event or
\* edge emission occurs (mirrors a thrown Julia exception unwinding the
\* rest of generate_stackified_flow!, discarding any partially-built bytes).
RejectNeverEmits == [][pc = "Reject" => UNCHANGED vars]_vars

=============================================================================
