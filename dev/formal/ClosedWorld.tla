-------------------------- MODULE ClosedWorld -----------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's closed-world collection fixpoint -- the    *)
(* `while true` loop inside `collect_closed_world`                         *)
(* (src/codegen/trimcollect.jl), with the cut of declared imports          *)
(* (`_prune_external_leaf_subgraphs`) at every merge. It is the sole       *)
(* mechanism by which the compiler decides which MethodInstances belong in *)
(* the plan.                                                               *)
(*                                                                         *)
(* WHAT THE REAL LOOP DOES. `CC.compile!` of a root (in a fresh            *)
(* interpreter) collects the root and every body Julia's own queue         *)
(* reaches from it (JuliaClosure): `collectinvokes!` (Compiler             *)
(* typeinfer.jl:1336 on 1.12, :1477 on 1.13) follows each `:invoke` and    *)
(* `:invoke_modify` edge to an inferred CodeInstance, and pushes to the    *)
(* invokelatest queue (which WT drains with a second `compile!`) the       *)
(* target of a `Core.finalizer` call, a `:cfunction`, and -- 1.13 only     *)
(* (:1523) -- the `:new` of a Function type. It does NOT materialize every *)
(* edge's target: an :invoke naming Julia's abstract MethodInstance leaves *)
(* that body uncollected (b107: g9(::Any) never entered `codeinfos`; the   *)
(* code's own comment, Base.with_output_color's `Function` argument), and  *)
(* the invokelatest enqueue is "a best-effort attempt"                     *)
(* (`compileable_specialization_for_call` returns nothing for no method    *)
(* table or more than one match). Those targets are `Unmaterialized`. But  *)
(* an original CAN be materialized: `compileable_specialization` (Compiler *)
(* ssair/inlining.jl:795-799, 1.12.7) puts the widened MI's cached         *)
(* CodeInstance in the :invoke when that signature was inferred in the     *)
(* same partition (A12C2). Those targets are `Widened`: each compile! call *)
(* may or may not materialize each of them (a nondeterministic choice).    *)
(*                                                                         *)
(* THE CUT. Julia's queue also infers a declared import's native fallback  *)
(* body, and what it calls, with the import's caller; that body is not the *)
(* Wasm component's. Every compile! output is cut before it merges         *)
(* (LeafCut): what the round's roots reach over the closed world's edges   *)
(* (`_closed_world_edge`: every :invoke, every hidden kind) through the    *)
(* bodies the output holds, never walking into an import, the imports left *)
(* out. The first collection is cut, and so is every later round's         *)
(* (`collect_new_pairs!`, LateCut = TRUE): a dynamic candidate enrolled in *)
(* a later round may call an import its round's compile! infers. Until     *)
(* batch 111 only the first collection was cut, and the superseded trim    *)
(* cut a late round's import body as a side effect, in a round where a     *)
(* retarget happened (LateCut = FALSE: MCClosedWorldLeaves'                *)
(* LateLeafUncut).                                                         *)
(*                                                                         *)
(* `collect_new_pairs!` merges the cut output's pairs whose (method,       *)
(* specTypes) is not yet in the plan. The entries' cut closure seeds the   *)
(* plan, and `invoke_seen` starts as it plus the imports. Each iteration   *)
(* then runs, in this order:                                               *)
(*   1. `_missing_explicit_invoke_mis` walks every collected IR. An        *)
(*      :invoke whose concrete call-site types select another              *)
(*      MethodInstance (an overlay, or a concrete one for Julia's abstract *)
(*      one) is RETARGETED in place (`nir_retarget_invoke!`; Retargets,    *)
(*      ScanInvokes). Each target of the body's edges                      *)
(*      (`_closed_world_edge`: :invoke, and the hidden kinds the collector *)
(*      follows, CollectorKinds) not yet in `invoke_seen` is enrolled and  *)
(*      collected. `invoke_seen` only grows.                               *)
(*   2. `_dynamic_dispatch_candidate_mis` resolves each collected dynamic  *)
(*      call site against the runtime classes the CURRENT plan observes    *)
(*      (`runtime_types` is rebuilt from `codeinfos` on every call). A     *)
(*      candidate enters `seen_disp` once, for good, and becomes a         *)
(*      `dynamic_roots` member (a dispatch row) whether or not it is       *)
(*      collected already; it is collected only if it is not. On 1.13      *)
(*      Julia's queue collects a closure body by its `:new` first, and     *)
(*      batch 111's first gate found the old rule ("a root only when not   *)
(*      collected") left those bodies with no row (RootsOnlyIfNew).        *)
(*   3. `_fused_multiply_add_mis` scans each body not yet in `fma_scanned` *)
(*      (an IdSet of CodeInfo objects) for `muladd_float`/`fma_float`; the *)
(*      `Base.fma_emulated` MethodInstances those lower to (FmaEdges) that *)
(*      are not collected are collected.                                   *)
(*   4. `changed || break`: the loop stops only once no step added a pair. *)
(* The loop only adds: no collected body is ever dropped. Steps 1, 2 and 3 *)
(* feed one shared fixpoint, because (L78 in test/parity_ratchet.jl)       *)
(* "[e]ither class can add IR containing edges of the other class, so      *)
(* sequential fixpoints are insufficient."                                 *)
(*                                                                         *)
(* THE DELETED TRIM (Trim). At c7f0c250, between steps 1 and 2, when a     *)
(* retarget superseded an original (`length(superseded_invokes) !=         *)
(* pruned_superseded`), `_prune_external_leaf_subgraphs(...;               *)
(* unreachable=true)` kept only the collected bodies its relation reached  *)
(* from the entries, `dynamic_roots` and `intrinsic_body_roots`. Batch 111 *)
(* (outcome A) deleted it: every positive instance sets Trim = FALSE. Trim *)
(* = TRUE stays only for MCClosedWorldTrimDropsBroken, which pins why it   *)
(* is gone: on a materialized dead original it drops a reachable callee    *)
(* with the original's subtree (b106 F1).                                  *)
(*                                                                         *)
(* HIDDEN-EDGE KINDS -- the edges no :invoke records. Two are WT's own,    *)
(* calls a builtin hides that Julia's codegen handles natively:            *)
(* "splat", a runtime-Vararg `Core._apply_iterate`                         *)
(* (`_apply_iterate_vararg_target_mi`), and "invoke_in_world",             *)
(* `Core.invoke_in_world(world, f, args...)` (`_invoke_in_world_target_mi`).*)
(* Four are the edges Julia's collectinvokes! follows besides :invoke      *)
(* (JuliaKinds, A2C1): "finalizer", "cfunction", "new_function" (1.13's    *)
(* `:new` of a Function type) and "invoke_modify". `_closed_world_edge` is *)
(* the one relation of all six (CollectorKinds = HiddenKinds), which the   *)
(* collector enrolls by and the cut keeps by. Where Julia's queue          *)
(* materializes an A2C1 target, compile! collected it with its caller and  *)
(* the collector's following adds nothing; where Julia leaves it           *)
(* unmaterialized, only the collector's following collects it.             *)
(*                                                                         *)
(* SCHEDULE. Every action is atomic and TLC explores every interleaving    *)
(* the code's order allows and more: a scan of one body may run before or  *)
(* after another's; with the trim (TrimDrops only), while a trim is        *)
(* pending only step 1 may continue before it.                             *)
(*                                                                         *)
(* BROKEN FLAGS (each a realistic mistake; TLC must reject each instance): *)
(*   RoundCeiling > 0  -- the retired `for _round in 1:8` cap (L78).       *)
(*   SwallowFailures   -- a try/catch that drops a failing specialization.*)
(*   Trim = TRUE       -- c7f0c250's trim on a materialized dead original: *)
(*                        it drops the original's subtree, and a reachable *)
(*                        callee with it (TrimDrops, b106 F1).             *)
(*   CollectorKinds # HiddenKinds -- the collector ignores a kind whose    *)
(*                        target Julia leaves unmaterialized (A2C1).       *)
(*   LateCut = FALSE   -- only the first collection is cut: a later        *)
(*                        round's compile! output merges an import's       *)
(*                        native body (LateLeafUncut).                     *)
(*                                                                         *)
(* WHAT IS GUARANTEED. With Trim = FALSE, LateCut = TRUE and every kind    *)
(* followed, no reachable body is ever missing (NoneMissing), no import is *)
(* ever collected (LeavesNeverCollected), and, on every shape whose        *)
(* originals are live or never materialized, the plan is exactly the       *)
(* reachable set (Completeness, EndsDone). What is not guaranteed is       *)
(* minimality when a widened original is materialized and no site keeps   *)
(* it live: dead code (NoGarbage, pinned as the finding                    *)
(* MCClosedWorldGarbageBroken, dev/MARCH.md 13.17 H9 (C9); the fix is a    *)
(* reachability pass before codegen, not a trim).                          *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS, AND WHY THAT IS SUFFICIENT. Julia's method   *)
(* universe, type lattice and MethodInstance identity collapse to opaque   *)
(* `Methods`/`Types` ids; the claims are about WORKLIST SHAPE (which scan  *)
(* enrolls what, what a cut keeps, when the loop may stop, whether a       *)
(* failure is loud). `CC.specialize_method`/`compile!` succeeding or       *)
(* throwing is the fixed adversarial CONSTANT `SpecializeFails`; compile!  *)
(* throws before its output is cut. Which sites retarget (concrete         *)
(* operands, an overlay match) is the CONSTANT Retargets; a body that      *)
(* invokes one MI from both a retargeted and an unretargeted site is not   *)
(* represented (another body's unretargeted site is). Whether Julia's      *)
(* queue materializes an edge's target is a property of the target         *)
(* (Unmaterialized, Widened), not of the edge; a Widened target's          *)
(* materialization is a free choice per compile! call, an over-            *)
(* approximation of "that signature was inferred in this partition". A     *)
(* HiddenEdges target is the MethodInstance WT's call site calls; Julia's  *)
(* best-effort enqueue either materializes that same MI or none. An        *)
(* import (ExternalLeaves) is a call-graph leaf: its native body's edges   *)
(* are Julia's (its compile! follows them), never the program's. The       *)
(* invokelatest queue's ccallable aliases are not modeled. "Framework      *)
(* roots are declarative" (L91) is `collected` seeded with the roots' cut  *)
(* closure at Init.                                                        *)
(*                                                                         *)
(* formal(src/codegen/trimcollect.jl collect_closed_world): the shared     *)
(* edge/dynamic-dispatch/intrinsic-body fixpoint collects every method     *)
(* reachable from the roots and no import, never stops early, never        *)
(* silently drops a reachable method whose specialization fails.           *)
(*                                                                         *)
(* Dart anchor: dart2wasm's own closed-world fixpoint is not in            *)
(* translator.dart -- it is the VM's global type-flow analysis dart2wasm   *)
(* invokes (pkg/dart2wasm/lib/compile.dart:513,                            *)
(* `globalTypeFlow.transformComponent(...)`), whose worklist               *)
(* (pkg/vm/lib/transformations/type_flow/analysis.dart, class `_WorkList`, *)
(* method `process()`) is the same shape modeled here:                     *)
(*   void process() {                                                     *)
(*     for (;;) {                                                         *)
(*       if (pending.isEmpty && !invalidateProtobufFields()) break;        *)
(*       ...                                                              *)
(*       processInvocation(pending.first);                                *)
(*     }                                                                  *)
(*   }                                                                    *)
(* an unconditional `for (;;)` fixpoint with no round cap and no method-   *)
(* count cliff -- the same worklist shape L78 locks WT's own loop to; and  *)
(* no trim: dart's worklist only adds. A dart import has no Dart body, so  *)
(* dart has nothing to cut.                                                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

(* WT's own hidden calls (`_closed_world_edge`'s :splat and :invoke_in_world) *)
WTKinds    == {"splat", "invoke_in_world"}
(* the edges Julia's collectinvokes! follows besides :invoke (A2C1) *)
JuliaKinds == {"finalizer", "cfunction", "new_function", "invoke_modify"}
HiddenKinds == WTKinds \cup JuliaKinds

CONSTANTS
    Methods,          \* finite universe of method ids
    Roots,            \* SUBSET Methods: framework/entry roots -- declarative (L91)
    Types,            \* finite universe of runtime-type ids (dynamic-dispatch evidence)
    InvokeEdges,      \* [Methods -> SUBSET Methods]: :invoke targets as Julia's inference writes them
    Retargets,        \* [Methods -> SUBSET (Methods \X Methods)]: <<original, replacement>> of each :invoke the scan retargets
    TypeSites,        \* [Methods -> SUBSET Types]: concrete types a body instantiates (:new, a folded literal, an allocating builtin)
    DynSites,         \* [Methods -> SUBSET Types]: abstract dynamic-call slot types present in a body
    DynTargets,       \* [Types -> SUBSET Methods]: dispatch candidates admitted for an observed runtime type
    SpecializeFails,  \* SUBSET Methods: methods whose CC.specialize_method/compile! throws (adversarial input)
    RoundCeiling,     \* Nat: 0 = unconditional (the real algorithm); k > 0 = the retired "for _round in 1:8" cap
    SwallowFailures,  \* BOOLEAN: FALSE = the real algorithm (a throw aborts); TRUE = a caught-and-dropped throw
    HiddenEdges,      \* [Methods -> SUBSET (Methods \X HiddenKinds)]: edges no :invoke records, with their kind
    Unmaterialized,   \* SUBSET Methods: targets compile! never collects when an edge names them (compiled only as a root)
    Widened,          \* SUBSET Methods: targets compile! may or may not collect when an edge names them (inlining.jl:795-799)
    CollectorKinds,   \* SUBSET HiddenKinds: the kinds the scan enrolls; HiddenKinds = the code (c7f0c250: WTKinds)
    Trim,             \* BOOLEAN: FALSE = the code (the superseded trim deleted); TRUE = c7f0c250's trim (TrimDrops)
    FmaEdges,         \* [Methods -> SUBSET Methods]: the Base.fma_emulated bodies a body's muladd_float/fma_float lower to
    ExternalLeaves,   \* SUBSET Methods: declared imports (`import_stubs`); Julia infers their native bodies, the plan never holds them
    LateCut,          \* BOOLEAN: TRUE = the code (every compile! output cut); FALSE = only the first collection cut
    RootsOnlyIfNew    \* BOOLEAN: FALSE = the code (every candidate is a root); TRUE = a collected candidate gets no row (c7f0c250, batch 111's first gate)

ASSUME /\ Roots \subseteq Methods
       /\ InvokeEdges \in [Methods -> SUBSET Methods]
       /\ Retargets \in [Methods -> SUBSET (Methods \X Methods)]
       /\ \A m \in Methods : \A p \in Retargets[m] : p[1] \in InvokeEdges[m] /\ p[2] # p[1]
       /\ HiddenEdges \in [Methods -> SUBSET (Methods \X HiddenKinds)]
       /\ Unmaterialized \subseteq Methods
       /\ Widened \subseteq Methods
       /\ Unmaterialized \cap Widened = {}
       /\ CollectorKinds \subseteq HiddenKinds
       /\ Trim \in BOOLEAN
       /\ FmaEdges \in [Methods -> SUBSET Methods]
       /\ ExternalLeaves \subseteq Methods \ Roots
       /\ LateCut \in BOOLEAN
       /\ RootsOnlyIfNew \in BOOLEAN

VARIABLES
    collected,        \* SUBSET Methods: methods with a (CodeInstance, CodeInfo) pair in `codeinfos`
    discarded,        \* SUBSET Methods: methods whose specialization was swallowed (SwallowFailures only)
    status,           \* "Running" | "Done" | "Rejected"
    steps,            \* Nat: scans that enrolled a new body -- what RoundCeiling bounds
    pruned,           \* SUBSET Methods: methods the trim dropped (history; Trim only)
    invokeScanned,    \* SUBSET collected: bodies step 1 has scanned -- their :invoke sites are retargeted
    invokeSeen,       \* SUBSET Methods: `invoke_seen`
    superseded,       \* SUBSET Methods: the originals retargets superseded (c7f0c250's `superseded_invokes`; Trim only)
    trimmedFor,       \* SUBSET Methods: `superseded` as of the last trim (`pruned_superseded`; Trim only)
    dynSeen,          \* SUBSET Methods: `seen_disp`
    dynRoots,         \* SUBSET Methods: `dynamic_roots` -- the dispatch rows' candidates (and the trim's roots, Trim only)
    fmaScanned,       \* SUBSET collected: bodies in `fma_scanned`
    fmaRoots          \* SUBSET Methods: c7f0c250's `intrinsic_body_roots` -- the trim's roots (Trim only)

vars == <<collected, discarded, status, steps, pruned, invokeScanned, invokeSeen,
          superseded, trimmedFor, dynSeen, dynRoots, fmaScanned, fmaRoots>>

----------------------------------------------------------------------------
HiddenTargets(m)  == {p[1] : p \in HiddenEdges[m]}
KindTargets(m, K) == {p[1] : p \in {q \in HiddenEdges[m] : q[2] \in K}}
CollectorHidden(m) == KindTargets(m, CollectorKinds)
Originals(m)     == {p[1] : p \in Retargets[m]}
(* a body's :invoke edges after the scan retargeted them -- the program WT runs *)
FinalInvoke(m)   == (InvokeEdges[m] \ Originals(m)) \cup {p[2] : p \in Retargets[m]}
(* the :invoke edges a collected body's IR holds now *)
CurrentInvoke(m) == IF m \in invokeScanned THEN FinalInvoke(m) ELSE InvokeEdges[m]
(* every original some site retargets *)
AllOriginals     == UNION {Originals(m) : m \in Methods}

(* the edges compile!'s collectinvokes! follows from a body, and the       *)
(* targets it materializes in a call that materializes the Widened targets *)
(* in Mat                                                                  *)
JuliaEdges(m, Mat) == (InvokeEdges[m] \cup KindTargets(m, JuliaKinds))
                      \ (Unmaterialized \cup (Widened \ Mat))

(* what `CC.compile!` of S collects: S (each a root, always compiled) and  *)
(* every body Julia's queue reaches -- an import's native body included,   *)
(* and whether or not the plan holds it                                    *)
RECURSIVE JuliaClosure(_, _)
JuliaClosure(S, Mat) ==
    LET Grown == S \cup UNION {JuliaEdges(m, Mat) : m \in S}
    IN  IF Grown = S THEN S ELSE JuliaClosure(Grown, Mat)

(* `_prune_external_leaf_subgraphs(out, roots, ExternalLeaves)`: the walk  *)
(* from the roots over each held body's `_closed_world_edge` edges (a      *)
(* fresh body's :invoke edges as Julia wrote them, every hidden kind),     *)
(* never into an import; it keeps what it reaches that `out` holds, the    *)
(* imports left out.                                                       *)
RECURSIVE CutWalk(_, _)
CutWalk(S, Out) ==
    LET Grown == S \cup UNION {InvokeEdges[m] \cup HiddenTargets(m) : m \in (S \cap Out) \ ExternalLeaves}
    IN  IF Grown = S THEN S ELSE CutWalk(Grown, Out)
LeafCut(S, Out) == (CutWalk(S, Out) \cap Out) \ ExternalLeaves

(* the pairs one round's compile! of S yields to the merge: cut when `cut` *)
Compiled(S, Mat, cut) == IF cut THEN LeafCut(S, JuliaClosure(S, Mat)) ELSE JuliaClosure(S, Mat)

(* `runtime_types`: rebuilt from the current plan on every call *)
Observed == UNION {TypeSites[m] : m \in collected}

PrunePending == Trim /\ superseded # trimmedFor


TypeOK ==
    /\ collected \subseteq Methods
    /\ discarded \subseteq Methods
    /\ status \in {"Running", "Done", "Rejected"}
    /\ steps \in Nat
    /\ pruned \subseteq Methods
    /\ invokeScanned \subseteq collected
    /\ invokeSeen \subseteq Methods
    /\ superseded \subseteq Methods
    /\ trimmedFor \subseteq superseded
    /\ dynSeen \subseteq Methods
    /\ dynRoots \subseteq Methods
    /\ fmaScanned \subseteq collected
    /\ fmaRoots \subseteq Methods

(* the first collection: compile! of the entries, always cut *)
Init ==
    /\ \E Mat \in SUBSET Widened :
         /\ collected = Compiled(Roots, Mat, TRUE)
         /\ invokeSeen = Compiled(Roots, Mat, TRUE) \cup ExternalLeaves
         /\ status = IF JuliaClosure(Roots, Mat) \cap SpecializeFails = {} THEN "Running" ELSE "Rejected"
    /\ discarded = {}
    /\ steps = 0
    /\ pruned = {}
    /\ invokeScanned = {}
    /\ superseded = {}
    /\ trimmedFor = {}
    /\ dynSeen = {}
    /\ dynRoots = {}
    /\ fmaScanned = {}
    /\ fmaRoots = {}

----------------------------------------------------------------------------
CeilingOpen == RoundCeiling = 0 \/ steps < RoundCeiling

(* `collect_new_pairs!(S)`: compile S in a fresh partition, cut the output *)
(* (LateCut), and merge the bodies not yet collected. A throw aborts the   *)
(* plan (L78), or, in the SwallowFailures variant, the failing bodies are  *)
(* dropped.                                                                *)
Enroll(S) ==
    \E Mat \in SUBSET Widened :
    LET raw   == JuliaClosure(S, Mat) \ collected
        fails == raw \cap SpecializeFails
        batch == Compiled(S, Mat, LateCut) \ collected
    IN  /\ steps' = IF batch # {} THEN steps + 1 ELSE steps
        /\ \/ /\ fails = {}
              /\ collected' = collected \cup batch
              /\ UNCHANGED <<discarded, status>>
           \/ /\ fails # {}
              /\ SwallowFailures
              \* the retired bug class: catch the throw and drop the candidate
              /\ collected' = collected \cup (batch \ fails)
              /\ discarded' = discarded \cup fails
              /\ UNCHANGED status
           \/ /\ fails # {}
              /\ ~SwallowFailures
              \* the real algorithm: a throw aborts the whole plan, located
              /\ status' = "Rejected"
              /\ UNCHANGED <<collected, discarded>>

(* Step 1 on one body: retarget its :invoke sites, enroll every target and *)
(* every hidden callee of a kind the collector knows not yet in            *)
(* `invoke_seen`. With the trim (TrimDrops), the retargets' non-root       *)
(* originals are superseded and the scan may run while a trim is pending:  *)
(* c7f0c250's scan walked every body before its trim ran.                  *)
ScanInvokes(m) ==
    /\ status = "Running"
    /\ CeilingOpen
    /\ m \in collected \ invokeScanned
    /\ LET proposals == (FinalInvoke(m) \cup CollectorHidden(m)) \ invokeSeen
       IN  /\ invokeScanned' = invokeScanned \cup {m}
           /\ superseded' = IF Trim THEN superseded \cup (Originals(m) \ Roots) ELSE superseded
           /\ invokeSeen' = invokeSeen \cup proposals
           /\ Enroll(proposals)
    /\ UNCHANGED <<pruned, trimmedFor, dynSeen, dynRoots, fmaScanned, fmaRoots>>

(* Trim only (c7f0c250's step 2, `_prune_external_leaf_subgraphs(...;      *)
(* unreachable=true)`): what its relation reaches from the entries and its *)
(* roots, never into an import.                                            *)
RECURSIVE PruneClosure(_)
PruneClosure(S) ==
    LET Live  == (S \cap collected) \ ExternalLeaves
        Grown == S \cup UNION {CurrentInvoke(m) \cup HiddenTargets(m) : m \in Live}
    IN  IF Grown = S THEN S ELSE PruneClosure(Grown)

PruneRoots == Roots \cup dynRoots \cup fmaRoots

Prune ==
    /\ status = "Running"
    /\ PrunePending
    /\ LET keep == (collected \cap PruneClosure(PruneRoots)) \ ExternalLeaves
       IN  /\ collected' = keep
           /\ pruned' = pruned \cup (collected \ keep)
           \* a dropped body's CodeInfo is gone: one merged again is fresh and unscanned
           /\ invokeScanned' = invokeScanned \cap keep
           /\ fmaScanned' = fmaScanned \cap keep
           /\ trimmedFor' = superseded
           /\ UNCHANGED <<discarded, status, steps, invokeSeen, superseded, dynSeen,
                          dynRoots, fmaRoots>>

(* Is there a dynamic call site, in a collected body, whose candidate for  *)
(* a currently observed class `seen_disp` has not yet seen? Shared by      *)
(* DiscoverDynamic, Finish and Idempotence. *)
DynamicWorkAvailable ==
    \E m \in collected :
        \E T \in (DynSites[m] \cap Observed) :
            \E n \in DynTargets[T] : n \notin dynSeen

(* Step 2 for one candidate: it enters `seen_disp` and `dynamic_roots`;   *)
(* it is collected only if it is not collected now.                        *)
DiscoverDynamic ==
    /\ status = "Running"
    /\ CeilingOpen
    /\ ~PrunePending
    /\ \E m \in collected :
         \E T \in (DynSites[m] \cap Observed) :
           \E n \in DynTargets[T] :
             /\ n \notin dynSeen
             /\ dynSeen' = dynSeen \cup {n}
             /\ IF n \in collected
                THEN /\ dynRoots' = IF RootsOnlyIfNew THEN dynRoots ELSE dynRoots \cup {n}
                     /\ UNCHANGED <<collected, discarded, status, steps>>
                ELSE /\ dynRoots' = dynRoots \cup {n}
                     /\ Enroll({n})
    /\ UNCHANGED <<pruned, invokeScanned, invokeSeen, superseded, trimmedFor, fmaScanned, fmaRoots>>

(* Step 3 on one body not in `fma_scanned`: collect the fma_emulated       *)
(* bodies its intrinsics lower to that are not collected (the trim's roots *)
(* at c7f0c250, `intrinsic_body_roots`).                                   *)
ScanFma(m) ==
    /\ status = "Running"
    /\ CeilingOpen
    /\ ~PrunePending
    /\ m \in collected \ fmaScanned
    /\ LET new == FmaEdges[m] \ collected
       IN  /\ fmaScanned' = fmaScanned \cup {m}
           /\ fmaRoots' = fmaRoots \cup new
           /\ Enroll(new)
    /\ UNCHANGED <<pruned, invokeScanned, invokeSeen, superseded, trimmedFor, dynSeen, dynRoots>>

(* `changed || break`: stop only once no step can add anything (and, with  *)
(* the trim, none is pending) -- a real, unconditional fixpoint.           *)
Finish ==
    /\ status = "Running"
    /\ ~PrunePending
    /\ collected \subseteq invokeScanned
    /\ collected \subseteq fmaScanned
    /\ ~DynamicWorkAvailable
    /\ status' = "Done"
    /\ UNCHANGED <<collected, discarded, steps, pruned, invokeScanned, invokeSeen,
                   superseded, trimmedFor, dynSeen, dynRoots, fmaScanned, fmaRoots>>

(* THE ROUND-CEILING VARIANT: a cap forces the plan "done" while work      *)
(* remains -- the retired `for _round in 1:8` / `length(ms) <= 64` bug     *)
(* class L78 forbids. Disabled in the real algorithm (RoundCeiling = 0).   *)
ForceStopAtCeiling ==
    /\ status = "Running"
    /\ RoundCeiling > 0
    /\ steps >= RoundCeiling
    /\ status' = "Done"
    /\ UNCHANGED <<collected, discarded, steps, pruned, invokeScanned, invokeSeen,
                   superseded, trimmedFor, dynSeen, dynRoots, fmaScanned, fmaRoots>>

Stutter ==
    /\ status # "Running"
    /\ UNCHANGED vars

Next ==
    \/ \E m \in Methods : ScanInvokes(m)
    \/ Prune
    \/ DiscoverDynamic
    \/ \E m \in Methods : ScanFma(m)
    \/ Finish
    \/ ForceStopAtCeiling
    \/ Stutter

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

----------------------------------------------------------------------------
(* The ground truth: every method reachable from Roots in the program WT  *)
(* runs -- retargeted :invoke edges, every hidden call of all six kinds,   *)
(* every intrinsic lowering's body, and observed-type-gated dynamic edges  *)
(* -- computed from the call graph alone, with no reference to the         *)
(* algorithm's state. An import is a leaf the program calls, not a body it *)
(* holds: none of its native body's edges or types is the program's, and   *)
(* the import itself is not in Reachable. Completeness is checked against  *)
(* THIS, not the algorithm's bookkeeping.                                  *)
RECURSIVE ReachClosure(_)
ReachClosure(S) ==
    LET Live              == S \ ExternalLeaves
        Obs               == UNION {TypeSites[m] : m \in Live}
        DirectTargets     == UNION {FinalInvoke(m) \cup HiddenTargets(m) \cup FmaEdges[m] : m \in Live}
        DynTargetsFrom(m) == UNION {DynTargets[T] : T \in (DynSites[m] \cap Obs)}
        DynAll            == UNION {DynTargetsFrom(m) : m \in Live}
        Grown             == S \cup DirectTargets \cup DynAll
    IN  IF Grown = S THEN S ELSE ReachClosure(Grown)

Reachable == ReachClosure(Roots) \ ExternalLeaves

(* An instance whose originals compile! never materializes. *)
OriginalsUnmaterialized == AllOriginals \subseteq Unmaterialized

----------------------------------------------------------------------------
(* Properties. Numbering matches the mission brief. *)

(* (2) Completeness: at the fixpoint, the plan is exactly the reachable set. *)
Completeness == status = "Done" => collected = Reachable

(* (2a) NoneMissing, Completeness's first half: at the fixpoint no         *)
(* reachable method is missing -- checked on MCClosedWorldGarbage, where   *)
(* the second half (NoGarbage) is the pinned finding.                      *)
NoneMissing == status = "Done" => Reachable \subseteq collected

(* (3) NoOptOut: no path may complete the plan missing a reachable method  *)
(* -- the round-ceiling / method-count-cliff bug class. In this model that *)
(* is the identical violation shape as Completeness (a "Done" plan that is *)
(* not equal to Reachable), so the same formula states both claims.        *)
NoOptOut == Completeness

(* (4) FailureIsLoud: a reachable specialization failure can only end the  *)
(* run in Rejected, never in a Done plan that is silently missing it.      *)
FailureIsLoud == status = "Done" => (Reachable \cap SpecializeFails = {})

(* (5) Idempotence: a "Done" plan really is a fixpoint -- no scan has      *)
(* anything left to add and no trim is pending.                            *)
Idempotence == status = "Done" =>
    /\ ~PrunePending
    /\ collected \subseteq invokeScanned
    /\ collected \subseteq fmaScanned
    /\ ~DynamicWorkAvailable

(* (6) NoGarbage, minimality in EVERY state: nothing outside Reachable is  *)
(* collected. The code does not guarantee it: a materialized dead original *)
(* is dead code (MCClosedWorldGarbageBroken, 13.17 H9 (C9)).               *)
NoGarbage == collected \subseteq Reachable

(* (7) RootsComplete: at the fixpoint every candidate of an observed      *)
(* dynamic site in a collected body is a dispatch root, however its body   *)
(* entered the plan (an edge, a root or the dynamic step): a candidate     *)
(* with no row is a dynamic call with no handler, a trap where Julia       *)
(* answers. MCClosedWorldKindsRootsOnlyIfNewBroken violates it.            *)
RootsComplete ==
    status = "Done" =>
        \A m \in collected : \A T \in (DynSites[m] \cap Observed) : DynTargets[T] \subseteq dynRoots

(* (8) LeavesNeverCollected, in EVERY state and so at every round: no      *)
(* import's native body is ever in the plan (MCClosedWorldLeaves; its      *)
(* LateLeafUncut variant breaks it).                                       *)
LeavesNeverCollected == collected \cap ExternalLeaves = {}

(* Support invariant: the worklist is genuinely finite -- each enrolling   *)
(* scan adds a body `invoke_seen`, `seen_disp` or an fma root admits once, *)
(* so `steps` is bounded and TLC's state space cannot be infinite. *)
StepsBounded == steps <= 2 * Cardinality(Methods)

(* (1) Termination, checked as a liveness PROPERTY in the .cfg files. *)
Terminates == <>(status # "Running")

(* (7) Acceptance: a program with no failing specialization is accepted   *)
(* on every behavior (non-vacuity of Done).                                *)
EndsDone == <>(status = "Done")

=============================================================================
