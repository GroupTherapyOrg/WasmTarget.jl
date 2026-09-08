---------------------------- MODULE BoxJoin --------------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's box-capture type join -- `box_contents_type`*)
(* (src/codegen/box_capture.jl:141-164), the analysis that recomputes a     *)
(* mutably-captured Julia variable's REAL type past `Core.Box{contents::    *)
(* Any}` erasure: the JOIN of every write ever made into the box. dart2wasm *)
(* never needs this reconstruction -- Dart's own static inference already   *)
(* knows a captured variable's declared type everywhere it is read or       *)
(* written (closures.dart:1102-1115's context-field type IS that type;      *)
(* translator.dart:2100 `translateTypeOfLocalVariable` hands it to every    *)
(* consumer). Julia instead reifies every mutated capture as one            *)
(* `Core.Box` whose `.contents` field Julia itself types `Any` (it does not *)
(* track the box flow-sensitively across closure boundaries), so WT must    *)
(* RECOMPUTE that type from the write sites to get dart's precision back:   *)
(* concrete join -> a typed cell (`Box{i64}` etc, a real Wasm field);       *)
(* anything else -> anyref (dart's top-type field, the safe fallback).      *)
(*                                                                          *)
(* WHAT THE REAL ALGORITHM DOES (the part this model checks).               *)
(*   (1) ENCLOSING WRITES (box_capture.jl:142-151): scan the box's OWN      *)
(*       function body for every `setfield!(box, :contents, v)` statement   *)
(*       (`_f3_contents_write_value`, :22-28, matched by the CALL SHAPE     *)
(*       alone -- it does not check which box a candidate `setfield!`       *)
(*       targets until the caller re-checks via `_f3_refers_to_box`,        *)
(*       :147), compute each write's operand type (`_f3_operand_type`,      *)
(*       :55-69), and fold them together. ANY write whose type is `Any`     *)
(*       forces an IMMEDIATE `return nothing` (:149) -- before even looking *)
(*       at closures. If NO enclosing write exists at all, ALSO `return     *)
(*       nothing` immediately (:152) -- both are the safe direction (no     *)
(*       false concrete type), never the unsound one.                      *)
(*   (2) CLOSURE WRITES (box_capture.jl:153-161): find every closure TYPE   *)
(*       that captures the box via a literal `%new(closure, ..., box, ...)` *)
(*       statement IN THE SAME function body (`_f3_box_captor_fields`,      *)
(*       matching the ORIGINAL, unrecursed logic of what used to be         *)
(*       `_f3_box_captors` -- scans `code`, not any closure's own body, and *)
(*       also records WHICH field of the closure struct received the box), *)
(*       retrieve each one's typed IR through its `:invoke`'s CodeInstance/ *)
(*       MethodInstance (`_f3_capturing_closure_bodies`, TRANSITIVE via     *)
(*       `_f3_collect_capturing_bodies!`), and fold in every                *)
(*       `setfield!(_, :contents, v)` FOUND DIRECTLY IN THAT CLOSURE'S OWN  *)
(*       code (:156-160), each write's result type computed via            *)
(*       `Core.Compiler.return_type` past the erasure (`_f3_write_result_   *)
(*       type`, :73-87). THIS STEP RECURSES: after retrieving a captor      *)
(*       closure's own body, `_f3_collect_capturing_bodies!` scans THAT     *)
(*       body for `getfield(#self#, boxfield)` (boxfield = the field that   *)
(*       received the box one hop up) feeding a FURTHER `:new` that         *)
(*       captures the SAME box object one level deeper, and recurses on     *)
(*       that SSA id -- any nesting depth, a `visited` set (keyed by        *)
(*       specTypes) guarding a recursive closure that captures itself. A    *)
(*       write living in such a grand-child (or deeper) closure is          *)
(*       therefore fully discoverable -- see THE FIX (formerly THE         *)
(*       FINDING) below.                                                   *)
(*   (3) THE JOIN (box_capture.jl:154,162-163): every type folded in step   *)
(*       (1) or (2) goes into ONE flat list (`types`), reduced with         *)
(*       `Union` (`reduce((a,b)->Union{a,b}, types)`, :162) and accepted     *)
(*       ONLY if the result `isconcretetype` (:163) -- i.e. every folded    *)
(*       write reported the EXACT SAME concrete type. `Union{Int64,         *)
(*       Float64}` (two different types) and `Union{Int64, Any}` (an        *)
(*       imprecise closure write) are both NOT concrete -> `nothing` ->     *)
(*       anyref, the same safe fallback as (1)'s short-circuits. This is a  *)
(*       plain SET join over a flat list -- `Union` is commutative and      *)
(*       associative, so mathematically the result cannot depend on fold    *)
(*       order; TLC below explores every discovery order as a ROBUSTNESS    *)
(*       check against a future refactor (e.g. turning the flat list into a *)
(*       BFS/DFS worklist to fix the gap in (2)) accidentally regressing to *)
(*       an order-dependent accumulator instead.                            *)
(*                                                                          *)
(* THE FIX (formerly THE FINDING; item (2) above -- CLOSED). Because the    *)
(* closure-discovery scan USED TO BE exactly ONE HOP from the box's own     *)
(* function, a write made by a closure NESTED INSIDE another captor closure *)
(* (created by THAT closure's own `:new`, not the box function's) never     *)
(* entered the join. If the box's own function wrote a concrete type (e.g.  *)
(* `x = 0`, Int64) and the one-hop child closure never wrote directly (only *)
(* called the grandchild), `box_contents_type` returned Int64 even when the *)
(* grandchild closure genuinely wrote a Float64 -- a Wasm cell would have   *)
(* been laid out as a narrow `Box{i64}` while a real write needed to store  *)
(* a Float64 into it, exactly the "silent mutable-capture 0" bug class this *)
(* file's `dev/HISTORY.md#closures-and-dynamic-dispatch` section is named   *)
(* for. CONFIRMED (pre-fix) by direct evaluation of `box_contents_type` on  *)
(* real typed IR (via `WasmTarget.get_typed_ir`, the one inference path)    *)
(* for                                                                     *)
(*   function outer(n); x = 0                                             *)
(*     @noinline function level1(m); @noinline function level2(k)          *)
(*       k > BIG ? (x = 3.5) : (x += k) end                                *)
(*       for i in 1:m; level2(i); end end                                  *)
(*     level1(n); x end                                                   *)
(* which returned `Int64` (WRONG -- should widen to `nothing`/anyref)       *)
(* although `x` is genuinely written both Int64 (init) and Float64          *)
(* (level2). `_f3_capturing_closure_bodies` is now TRANSITIVE (see item (2) *)
(* above): on the same IR it discovers BOTH `level1` and `level2`'s bodies, *)
(* and `box_contents_type` now correctly returns `nothing`. Regression-     *)
(* tested at the IR level in test/f3_box_capture_l0.jl (verified to fail on *)
(* the pre-fix one-hop code). Compiling this exact program end-to-end still *)
(* fails LOUDLY with `:unsupported_method` on `level1`'s own invoke (a      *)
(* SEPARATE, older gap: WT's closed-world/invoke dispatch does not yet      *)
(* resolve a closure that itself creates and invokes a further closure) --  *)
(* so this join fix is not yet exercised as an end-to-end differential      *)
(* case; it will be the moment that separate gap is fixed.                  *)
(*                                                                          *)
(* WHAT THIS MODEL ABSTRACTS, AND WHY THAT IS SUFFICIENT.                   *)
(*  - Julia's actual type lattice is collapsed to a flat one: a finite      *)
(*    CONSTANT set `ConcreteTypes` of pairwise-INCOMPARABLE leaf types      *)
(*    (Int64/Float64/... are never subtypes of one another -- the only      *)
(*    join two DIFFERENT concrete types ever produces in this algorithm is  *)
(*    "not concrete", i.e. dynamic) plus one extra tag `"AnyT"` (a write    *)
(*    site whose own operand type could not be pinned -- `_f3_operand_type` *)
(*    / `_f3_write_result_type`'s `Any` fallbacks) and `"None"` (a write    *)
(*    SITE that, in a given run, simply has no statement there at all --    *)
(*    the free choice of which of a fixed set of syntactic write slots is   *)
(*    actually present). This is exactly the granularity `box_contents_     *)
(*    type`'s own decision procedure operates at: it never asks whether one *)
(*    concrete type is "wider" than another, only whether a SET of folded   *)
(*    types has exactly one member.                                        *)
(*  - `f3_box_value_types` (the FORWARD VALUE-PROPAGATION fixpoint that     *)
(*    consumes this join's output to type box-DERIVED SSA operands, e.g.    *)
(*    `s += i`) and `f3_self_box_joins` (the closure-LOCAL fallback used    *)
(*    when the parent has already scalar-replaced the box away and there is *)
(*    no `%new(Core.Box)` left to seed from) are NOT modeled here: both     *)
(*    consume THIS join's answer rather than compute it, and neither        *)
(*    changes which write sites exist or what type each one reports -- the *)
(*    claims under test (soundness/completeness/order-independence/        *)
(*    monotonicity of the join ITSELF) are unaffected by how a downstream   *)
(*    pass propagates the settled answer.                                   *)
(*  - The "any candidate `setfield!(_, :contents, v)` regardless of WHICH   *)
(*    box it targets" looseness of `_f3_contents_write_value` (box_         *)
(*    capture.jl:22-28) -- real only when a single closure body captures    *)
(*    TWO DIFFERENT boxes, where a write to the OTHER box could leak into   *)
(*    this one's join -- is not modeled: it can only WIDEN a result (an     *)
(*    extra, unrelated type folded in can never make a join MORE concrete), *)
(*    so it is strictly weaker than the completeness gap in (2) above and   *)
(*    adds no new violation shape to the four claims below.                 *)
(*  - `Captures` is a plain `[Scopes -> SUBSET Scopes]` with no acyclicity  *)
(*    ASSUME: real Julia closure nesting is a rooted tree (a closure cannot *)
(*    be created before its own definition exists), but `ReachClosure`      *)
(*    below is a monotone fixpoint over a FINITE universe regardless, so    *)
(*    termination does not depend on it and the assumption is not needed    *)
(*    for any claim to be well-formed.                                     *)
(*                                                                          *)
(* formal(dev/formal/BoxJoin.tla): `box_contents_type` computes a SOUND     *)
(* join (a concrete result is chosen only when EVERY write anywhere the     *)
(* box can reach -- any nesting depth -- agrees on that exact type),        *)
(* independent of the ORDER writes are folded in (a lattice join), and      *)
(* never lets an invisible write narrow the cell (a write site the analysis *)
(* somehow still misses only ever costs precision -- forcing anyref --      *)
(* never soundness) -- discovery is TRANSITIVE (§(2) above), matching       *)
(* MCBoxJoin.cfg's TransitiveDiscovery = TRUE, the shape all four claims    *)
(* below require. MCBoxJoinIncompleteBroken.cfg (TransitiveDiscovery =      *)
(* FALSE) is kept as the PRE-FIX baseline TLC must still reject.            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Scopes,               \* finite set of closure scopes: the box's own function plus every
                          \* nested closure that (directly or transitively) captures the box
    Root,                 \* CONSTANT: the scope holding the `%new(Core.Box)` / enclosing writes
    Captures,             \* [Scopes -> SUBSET Scopes]: Captures[s] = closures CREATED (a literal
                          \* `:new`+`:invoke` pair) directly IN s's own code that also capture the box
    WriteSites,           \* finite set of abstract `setfield!(_, :contents, v)` statement ids
    ScopeOf,              \* [WriteSites -> Scopes]: which scope's OWN code textually holds this write
    ConcreteTypes,        \* finite set of concrete (pairwise-incomparable) Julia leaf types
    TransitiveDiscovery,  \* BOOLEAN: TRUE = closure writes discovered at ANY depth -- today's real
                          \* box_capture.jl (_f3_capturing_closure_bodies recurses, see the header);
                          \* FALSE = the PRE-FIX one-hop shape, kept as MCBoxJoinIncompleteBroken.cfg's
                          \* regression baseline (TLC must still reject it)
    OrderDependentJoin    \* BOOLEAN: TRUE = a BROKEN "last write wins" scalar accumulator instead
                          \* of the real flat-list-then-Union join; FALSE = the real algorithm

ASSUME Root \in Scopes
ASSUME Captures \in [Scopes -> SUBSET Scopes]
ASSUME ScopeOf \in [WriteSites -> Scopes]
ASSUME TransitiveDiscovery \in BOOLEAN
ASSUME OrderDependentJoin \in BOOLEAN
ASSUME ConcreteTypes \cap {"AnyT", "None", "NoWrites", "Dynamic"} = {}

Types == ConcreteTypes \cup {"AnyT"}   \* every value a write SITE can report

VARIABLES
    WriteType,       \* [WriteSites -> Types \cup {"None"}] -- chosen once at Init, then fixed
                      \* ("None" = this syntactic write slot has no statement in THIS run)
    pending,         \* SUBSET WriteSites -- discoverable writes not yet folded into the join
    seenTypes,       \* SUBSET Types -- the REAL algorithm's running set of distinct types folded
                      \* so far (box_capture.jl's flat `types` list, deduplicated -- a set join
                      \* does not care about multiplicity, only distinctness, matching `reduce(Union)`)
    overwriteType,   \* Types \cup {"NoWrites"} -- the BROKEN accumulator: last write folded wins
    status,          \* "Discovering" | "Done"
    prevResult       \* Types \cup {"NoWrites", "Dynamic"} (see TypeOK) -- AlgoResult as of JUST BEFORE the
                      \* most recent FoldOne, snapshotted so Monotonicity can be stated as a
                      \* plain per-state INVARIANT (comparing prevResult to the current AlgoResult)
                      \* rather than a `[][...]_vars` temporal property -- TLC reports the latter as
                      \* "Action property ... is violated", a phrasing dev/formal/run_tlc.sh's
                      \* violation regex does not recognize (it matches "Invariant .* is violated" /
                      \* "Temporal properties were violated" / "Deadlock reached" only), which would
                      \* silently misreport MCBoxJoinOrderBroken.cfg as "error" instead of the
                      \* expected violation. Same claim, a form the shared harness actually detects.

vars == <<WriteType, pending, seenTypes, overwriteType, status, prevResult>>

----------------------------------------------------------------------------
(* Derived structure -- pure functions of the (fixed-after-Init) WriteType  *)
(* plus the CONSTANT capture graph. Mirrors box_capture.jl's own steps.     *)

\* ReachClosure: every scope the box can reach by ANY chain of closure
\* creation -- the GROUND TRUTH a fully-recursive discovery would find.
RECURSIVE ReachClosure(_)
ReachClosure(S) == LET Grown == S \cup UNION {Captures[s] : s \in S}
                   IN IF Grown = S THEN S ELSE ReachClosure(Grown)

TrueReachableScopes == ReachClosure({Root})           \* ground truth: any depth, always
OneHopScopes         == {Root} \cup Captures[Root]     \* today's real algorithm: ONE hop only
AlgoReachableScopes  == IF TransitiveDiscovery THEN TrueReachableScopes ELSE OneHopScopes

\* ExistingWrites: the write SITES actually present in this run (box_capture.jl has no notion
\* of "None" -- a slot that simply is not a statement in the IR does not exist as a candidate
\* at all; "None" here is purely how this model lets Init choose, per run, which of a fixed set
\* of syntactic slots is populated).
ExistingWrites == {w \in WriteSites : WriteType[w] # "None"}

RootExistingWrites == {w \in ExistingWrites : ScopeOf[w] = Root}

\* box_capture.jl:149,152 -- an Any-typed enclosing write, or NO enclosing write at all, forces
\* `return nothing` BEFORE closures are even looked at. Always the safe direction (never a false
\* concrete type): both cases are folded here into "discover nothing", so the join below settles
\* on "NoWrites" (never converted into a false narrow concrete answer downstream).
RootForcesFallback == RootExistingWrites = {} \/ (\E w \in RootExistingWrites : WriteType[w] = "AnyT")

\* Discoverable: exactly the write sites box_contents_type's OWN traversal will fold in, given
\* TransitiveDiscovery. TrueWrites: every write the box can ACTUALLY receive at runtime, any
\* depth, unconditionally (reality does not short-circuit on an empty enclosing scope).
Discoverable == IF RootForcesFallback THEN {}
                ELSE {w \in ExistingWrites : ScopeOf[w] \in AlgoReachableScopes}

TrueWrites == {w \in ExistingWrites : ScopeOf[w] \in TrueReachableScopes}

\* JoinTypes: box_capture.jl:162-163's `reduce(Union) + isconcretetype` -- a set of folded
\* types settles on that ONE type only if every member agrees; "AnyT" in the set (an imprecise
\* write) or 2+ DIFFERENT concrete types both make the join "not concrete" (Dynamic = anyref).
JoinTypes(S) == IF S = {} THEN "NoWrites"
                ELSE IF "AnyT" \in S THEN "Dynamic"
                ELSE IF Cardinality(S) = 1 THEN (CHOOSE t \in S : TRUE)
                ELSE "Dynamic"

\* AlgoResult: the join box_contents_type would actually report at completion, under whichever
\* accumulator OrderDependentJoin selects.
AlgoResult == IF OrderDependentJoin THEN overwriteType ELSE JoinTypes(seenTypes)

\* TrueJoin: the join over EVERY write the box can really receive, any depth, unconditionally --
\* the ground truth AlgoResult is being checked against.
TrueJoin == JoinTypes({WriteType[w] : w \in TrueWrites})

----------------------------------------------------------------------------
(* Init: choose one write-type assignment from the supported class          *)
(* (Stackifier-style existential choice, made once and then fixed) --       *)
(* `pending` starts as exactly what the (CONSTANT-parameterized) algorithm  *)
(* would discover; TLC's exploration is over BOTH which types are chosen    *)
(* AND the order `pending` gets folded in.                                  *)

Init ==
    /\ WriteType \in [WriteSites -> Types \cup {"None"}]
    /\ pending = Discoverable
    /\ seenTypes = {}
    /\ overwriteType = "NoWrites"
    /\ status = "Discovering"
    /\ prevResult = "NoWrites"

\* FoldOne: process one discovered write. seenTypes accumulates the REAL algorithm's set-join
\* (box_capture.jl's flat `types` list); overwriteType tracks the BROKEN "last write wins"
\* scalar in parallel so both mechanisms can be compared against the SAME discovery/ordering
\* trace -- which one is "official" is selected by OrderDependentJoin in AlgoResult below.
\* prevResult snapshots AlgoResult from BEFORE this step, so Monotonicity can compare "the
\* answer just before" to "the answer now" as a plain per-state invariant.
FoldOne(w) ==
    /\ status = "Discovering"
    /\ w \in pending
    /\ prevResult' = AlgoResult
    /\ pending' = pending \ {w}
    /\ seenTypes' = seenTypes \cup {WriteType[w]}
    /\ overwriteType' = WriteType[w]
    /\ UNCHANGED <<WriteType, status>>

Finish ==
    /\ status = "Discovering"
    /\ pending = {}
    /\ status' = "Done"
    /\ UNCHANGED <<WriteType, pending, seenTypes, overwriteType, prevResult>>

Stutter == status = "Done" /\ UNCHANGED vars

Next == (\E w \in WriteSites : FoldOne(w)) \/ Finish \/ Stutter

Spec == Init /\ [][Next]_vars /\ WF_vars(Finish \/ (\E w \in WriteSites : FoldOne(w)))

----------------------------------------------------------------------------
(* The four claims. Numbering matches the mission brief. *)

TypeOK ==
    /\ WriteType \in [WriteSites -> Types \cup {"None"}]
    /\ pending \subseteq WriteSites
    /\ seenTypes \subseteq Types
    /\ overwriteType \in Types \cup {"NoWrites"}
    /\ status \in {"Discovering", "Done"}
    \* AlgoResult's full range: JoinTypes(...) yields ConcreteTypes \cup {"NoWrites","Dynamic"},
    \* but the BROKEN (OrderDependentJoin) accumulator can ALSO surface a raw "AnyT" write
    \* directly (overwriteType is not passed through JoinTypes) -- prevResult snapshots
    \* AlgoResult exactly, so it must cover both.
    /\ prevResult \in Types \cup {"NoWrites", "Dynamic"}

\* (1) SOUNDNESS: a concrete result is chosen only when it is the ACTUAL type of every write
\* the box can ever receive -- "no write is outside the cell's type; a typed cell is only
\* chosen when ALL writes agree." This is exactly what the one-hop discovery gap (§(2) of the
\* header) can violate: a write outside AlgoReachableScopes but inside TrueReachableScopes can
\* leave AlgoResult narrowly concrete while contradicting a write the algorithm never saw.
Soundness == status = "Done" =>
    (AlgoResult \in ConcreteTypes => \A w \in TrueWrites : WriteType[w] = AlgoResult)

\* (3) COMPLETENESS OF WRITES: identical violation shape to Soundness (ClosedWorld.tla's own
\* "NoOptOut == Completeness" pattern) -- "a write site the analysis cannot see must widen to
\* anyref, never leave a narrow cell" is precisely "no write outside AlgoResult's type", i.e.
\* Soundness restated from the missing-write side rather than the chosen-type side.
Completeness == Soundness

\* (2) ORDER-INDEPENDENCE: whatever order TLC folds Discoverable's writes in, the completed
\* result equals the plain mathematical join over that same set -- a lattice join (`Union`,
\* commutative+associative) cannot depend on the order its operands arrive in.
OrderIndependence == status = "Done" =>
    AlgoResult = JoinTypes({WriteType[w] : w \in Discoverable})

\* (4) MONOTONICITY: adding a write never narrows the cell. Widens(a,b): NoWrites precedes
\* everything; a type equals itself; Dynamic follows everything -- i.e. the running answer may
\* only move NoWrites -> some concrete T -> Dynamic, never sideways between two different
\* concrete types and never backward. Stated as a plain per-state INVARIANT via the `prevResult`
\* snapshot (comparing "the answer just before the last fold" to "the answer now") rather than
\* the more natural `[][Widens(AlgoResult, AlgoResult')]_vars` action property: TLC reports the
\* latter's violation as "Action property ... is violated", a phrasing dev/formal/run_tlc.sh's
\* result-classifying regex does not recognize (only "Invariant .* is violated" / "Temporal
\* properties were violated" / "Deadlock reached" are) -- confirmed by hand: MCBoxJoinOrder-
\* Broken.cfg genuinely finds the violation TLC-side but the shared harness misreported it as
\* "error" instead of the expected "violation" until restated this way.
Widens(a, b) == a = "NoWrites" \/ a = b \/ b = "Dynamic"

Monotonicity == Widens(prevResult, AlgoResult)

Terminates == <>(status = "Done")

=============================================================================
