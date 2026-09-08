-------------------------- MODULE ClosedWorld -----------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's closed-world collection fixpoint -- the    *)
(* `while true` loop inside `collect_closed_world`                         *)
(* (src/codegen/trimcollect.jl, lines 615-652), the sole mechanism by      *)
(* which the compiler decides which MethodInstances belong in the plan.    *)
(*                                                                         *)
(* WHAT THE REAL LOOP DOES. Two independent discovery mechanisms scan the  *)
(* code collected SO FAR and propose new MethodInstances:                  *)
(*   - `_missing_explicit_invoke_mis` walks every already-collected IR's   *)
(*     `:invoke` statements and returns targets not yet in the plan        *)
(*     (unconditional -- an explicit invoke edge is always followed; there *)
(*     is no environment opt-out).                                        *)
(*   - `_dynamic_dispatch_candidate_mis` walks every already-collected     *)
(*     IR's dynamic (SSA-callee) call sites and, for each abstractly-typed *)
(*     argument, resolves it against the set of concrete runtime types     *)
(*     OBSERVED anywhere in the collected program so far (`:new` sites and *)
(*     folded literal constructions) -- so a dynamic call's candidate set  *)
(*     can only grow as MORE code is collected.                            *)
(* Both mechanisms feed `collect_new_pairs!`, which compiles the newly     *)
(* proposed MethodInstances and merges only the genuinely NEW pairs        *)
(* (deduped by (method, specTypes)) into the plan. The `while true` loop   *)
(* re-runs BOTH mechanisms every iteration and stops only when NEITHER     *)
(* found anything new (`changed || break`) -- one unconditional shared     *)
(* fixpoint, not two sequential passes, because (L78 in                   *)
(* test/parity_ratchet.jl) "[e]ither class can add IR containing edges of  *)
(* the other class, so sequential fixpoints are insufficient." Framework   *)
(* roots (the compilation entries) are declarative: `entries` seed the     *)
(* plan directly and are protected from the invoke-supersession pruning   *)
(* that trims stale abstract call edges (L91).                            *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS, AND WHY THAT IS SUFFICIENT. Julia's method   *)
(* universe, type lattice, and MethodInstance identity are collapsed to    *)
(* opaque `Methods`/`Types` ids: the claim under test is purely about      *)
(* WORKLIST SHAPE (which discoveries enqueue what, when the loop is        *)
(* allowed to stop, whether a failure is loud) and does not depend on any  *)
(* Julia type-lattice detail. `CC.specialize_method` succeeding or         *)
(* throwing is collapsed to a fixed adversarial CONSTANT `SpecializeFails` *)
(* (a method either always specializes or always throws) rather than       *)
(* modeling Julia's actual specialization algorithm -- what matters for    *)
(* the claim is only whether a throw during collection of a REACHABLE      *)
(* method can be silently absorbed, not why it throws. The                 *)
(* MethodInstance-identity bookkeeping in `_missing_explicit_invoke_mis`   *)
(* (original vs. re-specialized invoke target) and the                     *)
(* `_prune_external_leaf_subgraphs` reachability trim it triggers are      *)
(* abstracted away entirely: they exist to keep stale abstract call edges  *)
(* out of the FINAL codegen inputs, but they do not change WHICH methods   *)
(* end up reachable, which is the only thing Completeness/NoOptOut/        *)
(* FailureIsLoud/Idempotence are claims about. "Framework roots are        *)
(* declarative" (L91) is modeled by seeding `collected` with `Roots`       *)
(* unconditionally at Init, with no discovery step required to admit them. *)
(*                                                                         *)
(* Like SchedulerWake.tla, every action below is atomic and TLC explores   *)
(* all interleavings of the two discovery mechanisms; this is what proves  *)
(* Completeness independent of discovery ORDER, which the real code relies *)
(* on (nothing in `collect_closed_world` fixes an order between the two    *)
(* mechanisms, or within a single method's outgoing edges).                *)
(*                                                                         *)
(* formal(src/codegen/trimcollect.jl collect_closed_world): the shared     *)
(* invoke/dynamic-dispatch fixpoint always collects exactly the methods    *)
(* reachable from the roots, never stops early, and never silently drops a *)
(* reachable method whose specialization fails.                            *)
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
(* count cliff -- the same worklist shape L78 locks WT's own loop to.      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Methods,          \* finite universe of method ids
    Roots,            \* SUBSET Methods: framework/entry roots -- declarative (L91)
    Types,            \* finite universe of runtime-type ids (dynamic-dispatch evidence)
    InvokeEdges,      \* [Methods -> SUBSET Methods]: explicit :invoke targets in a collected method's IR
    TypeSites,        \* [Methods -> SUBSET Types]: concrete types instantiated (:new) in a collected method's IR
    DynSites,         \* [Methods -> SUBSET Types]: abstract dynamic-call slot types present in a collected method's IR
    DynTargets,       \* [Types -> SUBSET Methods]: concrete dispatch targets admitted for an observed runtime type
    SpecializeFails,  \* SUBSET Methods: methods whose CC.specialize_method throws (adversarial input)
    RoundCeiling,     \* Nat: 0 = unconditional (the real algorithm); k > 0 = the retired "for _round in 1:8" cap
    SwallowFailures   \* BOOLEAN: FALSE = the real algorithm (a throw aborts); TRUE = a caught-and-dropped throw

VARIABLES
    collected,        \* SUBSET Methods: methods with a compiled (CodeInstance, CodeInfo) pair -- codeinfos
    pending,          \* SUBSET Methods: the worklist -- discovered but not yet collected
    discarded,        \* SUBSET Methods: methods whose specialization was swallowed (SwallowFailures branch only)
    observedTypes,    \* SUBSET Types: union of TypeSites over `collected` -- the real code's `runtime_types`
    status,           \* "Running" | "Done" | "Rejected"
    steps             \* Nat: discovery actions taken so far -- what RoundCeiling bounds

vars == <<collected, pending, discarded, observedTypes, status, steps>>

Known == collected \cup pending \cup discarded

TypeOK ==
    /\ collected \subseteq Methods
    /\ pending \subseteq Methods
    /\ discarded \subseteq Methods
    /\ observedTypes \subseteq Types
    /\ status \in {"Running", "Done", "Rejected"}
    /\ steps \in Nat

Init ==
    /\ collected = Roots
    /\ pending = (UNION {InvokeEdges[m] : m \in Roots}) \ Roots
    /\ discarded = {}
    /\ observedTypes = UNION {TypeSites[m] : m \in Roots}
    /\ status = "Running"
    /\ steps = 0

----------------------------------------------------------------------------
(* Is there a dynamic call site, in an already-collected method, whose     *)
(* observed-type-gated candidate has not yet been discovered? Shared by    *)
(* DiscoverDynamic (which acts on a witness), Finish's stopping condition, *)
(* and the Idempotence property, so all three agree on one definition.     *)
DynamicWorkAvailable ==
    \E m \in collected :
        \E T \in (DynSites[m] \cap observedTypes) :
            \E n \in DynTargets[T] :
                n \notin Known

(* Collect one pending method: specialize it (or discover that it throws). *)
CollectMethod(m) ==
    /\ status = "Running"
    /\ m \in pending
    /\ (RoundCeiling = 0 \/ steps < RoundCeiling)
    /\ steps' = steps + 1
    /\ \/ /\ m \in SpecializeFails
          /\ SwallowFailures
          \* the retired bug class: catch the throw and just drop the candidate
          /\ pending' = pending \ {m}
          /\ discarded' = discarded \cup {m}
          /\ UNCHANGED <<collected, observedTypes, status>>
       \/ /\ m \in SpecializeFails
          /\ ~SwallowFailures
          \* the real algorithm: specialize_method is never wrapped in a
          \* swallowing try/catch (L78) -- a throw aborts the whole plan
          /\ status' = "Rejected"
          /\ pending' = pending \ {m}
          /\ UNCHANGED <<collected, observedTypes, discarded>>
       \/ /\ m \notin SpecializeFails
          /\ collected' = collected \cup {m}
          /\ pending' = (pending \ {m}) \cup (InvokeEdges[m] \ (collected' \cup discarded))
          /\ observedTypes' = observedTypes \cup TypeSites[m]
          /\ UNCHANGED <<status, discarded>>

(* Re-scan every currently-collected method's dynamic call sites against   *)
(* the CURRENT observed-types set and enqueue one newly-admitted target.   *)
(* Enabled independently of CollectMethod and re-evaluated after every     *)
(* step -- this is the "one shared fixpoint" (L78): a dynamic edge that     *)
(* was not yet resolvable can become resolvable after any later step that  *)
(* grows `observedTypes`, from either discovery mechanism.                 *)
DiscoverDynamic ==
    /\ status = "Running"
    /\ (RoundCeiling = 0 \/ steps < RoundCeiling)
    /\ \E m \in collected :
           \E T \in (DynSites[m] \cap observedTypes) :
               \E n \in DynTargets[T] :
                   /\ n \notin Known
                   /\ pending' = pending \cup {n}
    /\ steps' = steps + 1
    /\ UNCHANGED <<collected, discarded, observedTypes, status>>

(* The loop's `changed || break`: stop only once neither mechanism can add *)
(* anything more -- a real, unconditional fixpoint. *)
Finish ==
    /\ status = "Running"
    /\ pending = {}
    /\ ~DynamicWorkAvailable
    /\ status' = "Done"
    /\ UNCHANGED <<collected, pending, discarded, observedTypes, steps>>

(* THE BROKEN VARIANT: a round/method-count cap forces the plan "done"     *)
(* even though the worklist (or a still-resolvable dynamic candidate) is   *)
(* nonempty -- the retired `for _round in 1:8` / `length(ms) <= 64` bug    *)
(* class L78 forbids. Disabled in the real algorithm (RoundCeiling = 0),   *)
(* so this action never fires there.                                       *)
ForceStopAtCeiling ==
    /\ status = "Running"
    /\ RoundCeiling > 0
    /\ steps >= RoundCeiling
    /\ status' = "Done"
    /\ UNCHANGED <<collected, pending, discarded, observedTypes, steps>>

Stutter ==
    /\ status # "Running"
    /\ UNCHANGED vars

Next ==
    \/ \E m \in Methods : CollectMethod(m)
    \/ DiscoverDynamic
    \/ Finish
    \/ ForceStopAtCeiling
    \/ Stutter

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

----------------------------------------------------------------------------
(* The ground truth: every method reachable from Roots through any mix of  *)
(* invoke edges and observed-type-gated dynamic edges, computed purely     *)
(* from the (nondeterministic) call graph -- with no reference to the      *)
(* algorithm's own state (collected/pending/observedTypes). Completeness   *)
(* is checked against THIS, not against the algorithm's own bookkeeping.   *)
RECURSIVE ReachClosure(_)
ReachClosure(S) ==
    LET Observed          == UNION {TypeSites[m] : m \in S}
        DirectTargets      == UNION {InvokeEdges[m] : m \in S}
        DynTargetsFrom(m)  == UNION {DynTargets[T] : T \in (DynSites[m] \cap Observed)}
        DynAll             == UNION {DynTargetsFrom(m) : m \in S}
        Grown              == S \cup DirectTargets \cup DynAll
    IN  IF Grown = S THEN S ELSE ReachClosure(Grown)

Reachable == ReachClosure(Roots)

----------------------------------------------------------------------------
(* Properties. Numbering matches the mission brief. *)

(* (2) Completeness: at the fixpoint, the plan is exactly the reachable set. *)
Completeness == status = "Done" => collected = Reachable

(* (3) NoOptOut: no path may complete the plan missing a reachable method  *)
(* -- the round-ceiling / method-count-cliff bug class. In this model that *)
(* is the identical violation shape as Completeness (a "Done" plan that is *)
(* not equal to Reachable), so the same formula states both claims.        *)
NoOptOut == Completeness

(* (4) FailureIsLoud: a reachable specialization failure can only end the  *)
(* run in Rejected, never in a Done plan that is silently missing it.      *)
FailureIsLoud == status = "Done" => (Reachable \cap SpecializeFails = {})

(* (5) Idempotence: a "Done" plan really is a fixpoint -- neither          *)
(* discovery mechanism has anything left to add.                           *)
Idempotence == status = "Done" => (pending = {} /\ ~DynamicWorkAvailable)

(* Support invariant: the worklist is genuinely finite -- `Known` only     *)
(* grows and every method enters `pending` at most once ever, so `steps`   *)
(* is bounded and TLC's state space cannot be infinite. *)
StepsBounded == steps <= 2 * Cardinality(Methods)

(* (1) Termination, checked as a liveness PROPERTY in the .cfg files. *)
Terminates == <>(status # "Running")

=============================================================================
