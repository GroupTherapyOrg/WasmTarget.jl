# The finishing march (PR #122) — one pathway, measured, dart-anchored

This document is the single tractable place for the march. Every phase below starts from a
**measured** number, follows a **named dart2wasm structure** (or is explicitly quarantined as a
Julia-only necessity with a differential proof), and ends at a **machine-checked exit** in
`test/parity_ratchet.jl`. Nothing here is a guess; where a number came from a census script, the
script lives under the session scratchpad and its regex is stated.

Oracle: dart-lang/sdk **`898a1e4bbfbc472dc0a9505dc7d2e4c21d6f856e`** (the `dev/PARITY_MASTER.md`
pin; the local checkout was moved to it on 2026-09-01). Ground truth: the Julia compiler's typed IR
under WasmTarget's own `WasmInterpreter` (`src/codegen/ir.jl:17-35`). Soundness gate: native-vs-wasm
differential. These are three different oracles and none substitutes for another.

## 0. End state

The march is done when the tree is a **clean, perfect foundation** for agent-driven development:

1. **Zero parallel pathways** — every construct has one lowering path, and it is locked.
2. **Zero stale code or bloat** — no dead definitions, no fossil comments, no debug toggles dart
   doesn't have, no half-wired campaigns.
3. **Nothing dart2wasm doesn't do** — every remaining structure carries a `parity(` anchor to a dart
   file:line at the pinned commit, or sits in the named Julia-only quarantine tier with a
   differential proof (Int128, checked overflow, `FunctionRegistry`, the `jl_*` runtime surface).
4. **Strict in every regard** — typed internal APIs, import hygiene enforced, structured
   source-located diagnostics for every unsupported construct (dart's two-tier model), unknown IR
   heads reject loudly.
5. **Fast, precise feedback** — a change to any family is verifiable in seconds, and a failure
   names its site. The analogue is Rust's borrow checker: the structure makes whole classes of
   wrong implementations impossible to land silently.

## 1. Measured baseline (2026-09-01, `wt-p0-strict-hygiene` @ `7897b316`)

| Dimension | Measurement |
|---|---|
| src | 39,052 lines / 37 files; `compile_call!` 4,583 lines (180 `elseif`), `compile_invoke!` 2,045 (120), `compile_foreigncall!` 995 |
| Enforcement | 102 zero-locks (95 → 102 in P0); ratchets R3 `infer_value_type` 127 · R5 `julia_type_reguess` 82 · R7 raw coercion ops 109 · R11 patch markers 454 · R14 12 · R15 2 · R17 unwrapped emissions 29 |
| Ladder arms | calls.jl `is_func(func, :` **123** (35 on ops the intrinsics table already covers) · invoke.jl `name === :` **61** · statements.jl `name === :` **59** |
| Sediment | 839 campaign tags (`march*` 244, `P2-batch*` 34 = narration; `parity(` 95 = oracle anchors, keep) · **693** commented-out code lines (interpreter.jl 300) · **16** `WT_*` env toggles gating ~65 lines · 1,107 `local` decls (calls.jl 448) · 20 TODO/FIXME (all constraint-bearing) |
| Dead definitions | **54** with zero references outside their definition (corrected census, identifier-exact regex handling `!` names) — ~30 are unused builder primitives (kept: dart's `wasm_builder` is a complete instruction library), **~24 codegen leftovers** (delete) · 10 names alive only as test pins · 10 exports with zero references outside src |
| Duplication vs dart | type translation: **two ~200-line chains** (`get_concrete_wasm_type` types.jl:2144, `julia_to_wasm_type_concrete` context.jl:379) with **live drift** on `Union{Nothing,T}` (EqRef vs nullable ConcreteRef) · coercion funnel (`convert_type!`, `narrow_length_to_i32!`/`widen_length_to_i64!`) has **4 callers vs ~35 inline re-derivations** · string concat duplicate 45 lines · `ref_i31!` dead · boxing / value emission / dispatch families already at parity |
| Downstream surface | 21 of 55 exports used by Therapy/WasmMakie/WasmPlot/Snapshot; **`WasmValType` used 60+ times but not exported**; 7 builder internals reached unqualified by Therapy; all 6 `compile_multi` kwargs live |
| Inner loop | `using WasmTarget` 0.43 s · first `compile` 0.17 s · ratchet 2.9 s · smoke 14.4 s (59 cases, 13 groups) · shard 0 5.4 min local / 23 min CI-Windows · full gate 18–46 min · **no per-phase filter exists** (phases are LPT-packed onto shards, runtests.jl:402-464) |
| Canary frontier | SimpleDiffEq: `saveat`/interpolation/`sol.u`/`ContinuousCallback` compile (differential owed), adaptive blocked by `apply_type(Pairs,…)` outside the concrete-eval whitelist · OrdinaryDiffEq Tsit5: blocked at `ODEProblem` construction because the `isinplace` overlay lives in the SimpleDiffEq ext · MOI `Model{Float64}()`: **crash** in `struct_set!` — `setfield!` casts the object but not an `AnyRef` value into a concrete field (calls.jl:3663-3666) · negative controls: 7/10 reject cleanly, `readline(stdin)` and `eval` **crash** instead of classifying |

## 2. Oracle anchors (dart2wasm @ `898a1e4b`, `pkg/dart2wasm/lib/`)

| Structure | dart | What WT copies |
|---|---|---|
| Numeric operator table | `_binaryOperatorMap` intrinsics.dart:436-472 — **diagonal only** (bool/int/double), 22 entries, keyed on canonical wasm value types **after** narrowing | `INTRINSIC_BINOPS` stays diagonal; never grows width keys |
| Unary / conversion tables | `_unaryOperatorMap` :474-503, `_inlineUnaryOperatorMap` :505-576, `_unaryResultMap` :578-583 | a second table for unary + conversion intrinsics |
| Narrow-width extension | storage-type-driven, upstream of the lookup: `readIntArray` :3490-3533 (`innerExtend`/`outerExtend`) | one wrap-channel function, caller-side |
| Low-level numeric switch | WasmI32/F64 member switch :710-929 incl. `copysign/min/max` :902-925 | float `_fast`/copysign/min/max sit below the table, not in it |
| Entry funnels | nullable-return, fall-through on null: :607, :685 (binary lookup :995, unary :1007), :1018 | every registry entry returns `nothing` = "use generic lowering" |
| Call primitives | exactly two: `call()` code_generator.dart:733, `_virtualCall` :2028 | already mirrored (L10/L36/L49/L50) |
| Identity registry | `kernel_nodes.dart` mixin, 201 `late final` lookups; `MemberIntrinsic`/`StaticIntrinsic` enums keyed (library, class, name) with `_lookup` :75-100, :401-428; unknown ⇒ `throw 'Unhandled …'` | invoke/foreigncall arms become identity-keyed registries with loud defaults |
| Type translation | `translateType` translator.dart:1044 → `translateStorageType` :1067; nullability computed **once** | one `wasm_storage_type` |
| Coercion | `convertType` translator.dart:1597 | `convert_type!` + its named wrappers, adopted everywhere |
| Diagnostics | two tiers: internal `throw` (intrinsics.dart:786, 878, …) vs structured `DiagnosticReporter` with source location (target.dart:719-751; `wasm_library_checks.dart`:43-243) | `StackImbalanceError` is internal-tier only; every user-facing unsupported construct is `record_unsupported!` |
| Host boundary | `wasm:import`/`wasm:export` pragma → functions.dart:90-189; **separate** `translateExternalType` translator.dart:1239 restricting what crosses | the host-import path and any sidecar ABI |
| Capability options | `TranslatorOptions` translator.dart:48-89 | the capability manifest (roadmap item 2) |
| **Absent in dart** | checked overflow, Int128, debug env toggles in codegen, per-op width keys, a static-call registry (Kernel pre-resolves targets) | quarantine tier; delete toggles; `FunctionRegistry` is a documented Julia necessity |

## 3. Julia ground truth (typed IR under `WasmInterpreter`)

- Every numeric intrinsic reaches codegen as a **`GlobalRef`** whose module varies (`Base.add_int`,
  `Core.zext_int`, `Base.Math.min_float`); `is_func` matches by name. No `:invoke` for intrinsics.
- Base does **not** normalize narrow types: `Int8+Int8` is a raw `add_int` on Int8; mixed-width
  promotion inserts an explicit `sext_int`/`zext_int`. Normalization is the consumer's job.
- Two "checked" shapes: `div`/`rem` → value-returning `checked_sdiv_int` (traps);
  `checked_add` → `Tuple{T,Bool}`-returning `checked_sadd_int` + branch to `throw_overflowerr`.
- `Int128` is an opaque primitive in the IR (`add_int::Int128`); the two-i64 split is WT's alone.
- Node kinds are stable 1.12 ↔ 1.13 (3 version guards in src, all in overlay bodies); every real
  1.13 break was an **inferred type shape** (Any-typed operands, `Memory` width unions).
- `:splatnew` and `:copyast` have zero handling in src.
- 152 `@overlay` methods; `inline_cost_threshold=500`; concrete-eval disabled except a type-level
  allowlist (`_is_typelevel_foldable`) — the shape an overlay body is written in is the shape that
  reaches the ladders.

## 4. The pathway

Ordering principle, from the repo's own history: **metricized campaigns finish, unmetricized ones
stall** (the byte-bridge campaign had R2 from day one and locked; the M11 table had no metric and
froze half-wired). So: instrument → delete → unify → lock → canaries. Every phase names its dart
anchor, its verification lane, its agent tier, and its exit.

### Phase 1 — Instrument and fix the inner loop

- New ratchet metrics (grep thunks in `test/parity_ratchet.jl`, all version-independent):
  `R19_call_is_func_arms` (123) · `R20_invoke_name_arms` (61) · `R21_statements_name_arms` (59) ·
  `R22_table_covered_ladder_arms` (35; keys parsed from `intrinsics_table.jl`) ·
  `R23_dead_codegen_defs` (24, from the census list) · `R24_debug_env_toggles` (15; `WT_VALIDATE`
  excluded) · `R25_commented_out_code` (693) · `R26_campaign_narration_tags` (`march\d+`+`P2-batch`,
  278) · `R27_coercion_funnel_bypass` (~35, the pointerref/foreigncall/types.jl sites) ·
  `R28_type_translation_chains` (2).
- Inner loop: `WT_PHASE=<substring>` selection in the `@pphase` mechanism (runtests.jl:402-464) so
  one phase runs alone; the byte-identity probe becomes `test/probe_bytes.jl` (sha256 of a fixed
  probe corpus; `WT_PROBE_RECORD=1` re-baselines) — the structural-change detector for every
  refactor below.
- Exit: ratchet green with the ten new metrics; `WT_PHASE="Phase 15"` completes in under 90 s.
- Tier: haiku (mechanical thunks, exact regexes given); orchestrator negative-tests each thunk.

### Phase 2 — Bloat nuke (every commit byte-identical unless stated)

| Step | Measured start | Action | Exit |
|---|---|---|---|
| 2a dead codegen defs | 24 | delete (list from the corrected census; builder primitives excluded) | R23 → 0 → lock |
| 2b test-only pins of deleted features | 10 names (`ref_i31!`, `catch_all_clause`, `emit_phi_local_set!`, …) | delete the src definition **and** rewrite the test as a lock on the deletion (grep-lock), or fold into `test/utils.jl` if genuinely a helper | census = 0 |
| 2c debug toggles | 15 | delete every `WT_DBG_*`/`WT_TRACE_*`/`WT_LOG_*`/`WT_DUMP_*`/`WT_AUDIT_*`/`WT_CUR_FN`/`WT_BUILDER_TRACE` gate and its gated code; the builder's `StackImbalanceError` already carries the stack snapshot and Julia statement — that is dart's diagnostic, not a trace log | R24 → 0 → lock |
| 2d commented-out code | 693 lines | delete; anything that is genuinely documentation becomes a docstring or a plain comment without code | R25 → 0 → lock |
| 2e campaign narration | 278 tags (+ `PURE-` prefixes reviewed per file) | strip narration; keep constraint-bearing content as untagged comments; keep every `parity(` anchor | R26 → 0 → lock; R11 tightened |
| 2f string concat | 45 lines | `compile_string_concat_b` → thin call into `compile_string_concat_many_b` | **differential** (loop shape changes bytes) — smoke `strings_classed` + `WT_PHASE="Phase 15"` |
| 2g exports | 10 zero-reference exports | de-export those with no docs entry; documented API (`compile_with_sourcemap`, cache API, `compile_with_base`, `compile_from_codeinfo`) is **kept** — removing it is a release decision, not a census outcome | ExplicitImports green; downstream CI green |

Tier: haiku per file with the probe lane; sonnet for 2f. Orchestrator reviews every diff.

### Phase 3 — Numeric registry, dart-verbatim (R22: 35 → 0)

1. Table completeness: add `gt_float`/`ge_float`; delete the 6 float arms now dead below the table
   (probe byte-identical).
2. `INTRINSIC_UNOPS` — dart's second map: `not_int`, `neg_int` (≤64-bit), `ctlz/cttz/ctpop_int`,
   `neg_float`, `abs_float`, `sqrt_llvm`, `floor/ceil/trunc/rint_llvm`, `sext/zext/trunc_int`,
   `fptosi/fptoui/sitofp/uitofp/fpext/fptrunc`, `bitcast` — keyed on canonical wasm types with a
   result-type map (`_unaryResultMap`). ~17 arms.
3. The wrap channel: **one** storage-type-driven normalization function (shape of `readIntArray`'s
   `innerExtend`/`outerExtend`) used by comparisons, div/rem, and shift counts; the div/rem arms then
   route table + guard.
4. `src/codegen/julia_numeric_tier.jl` — the named quarantine (`parity(quarantine: no dart
   equivalent)`): Int128 (14 arms → one op-keyed registry over `emit_int128_*!`), checked overflow
   (6 arms → one op-keyed registry with the `Tuple{T,Bool}` contract), 3-arg (`muladd`/`fma`),
   mixed-width shifts, `bswap`. Same nullable-return fall-through contract as the intrinsifier.
5. `min/max/copysign_float` and `_fast` variants: alias the `_fast` names onto the table entries;
   arms deleted.
6. `compile_call!`'s binary-op section becomes a thin funnel: table → unop table → quarantine tier →
   generic. (dart's `generateStaticIntrinsic` is itself 618 lines: the target is the **funnel**
   shape, not a line count.)

Exit: R22 = 0 → lock `L104_table_ops_have_no_ladder_arm` (per-symbol exclusivity: every table key ⇒
zero unannotated `is_func(func, :key)` arms). Verify: probe byte-identity for steps 1/2/5/6;
differential for 3/4 (smoke `numerics` + `WT_PHASE` on Phases 59/60/72 and STRESS-1000/1001).
Tier: sonnet for 2–4 (registry contracts fixed by the orchestrator first); haiku for 1/5.

### Phase 4 — Duplication collapse (one function per job)

1. `wasm_storage_type(T, mod, registry)` = `translateStorageType`, nullability computed once;
   `get_concrete_wasm_type` and `julia_to_wasm_type_concrete` become thin wrappers, then are
   deleted. This **fixes** the `Union{Nothing,T}` drift (the precise nullable `ConcreteRef` wins);
   differential on nullable-struct locals, with cases added to smoke `phi_union`. R28 → 1 → lock.
2. Coercion funnel adoption: the ~35 bypass sites route through `narrow_length_to_i32!` /
   `widen_length_to_i64!` / `convert_type!`; byte-identical. R27 → 0 → lock.
3. `FunctionRegistry` documented as quarantine (Julia's frontend does not hand codegen pre-resolved
   targets the way Kernel does) with its differential proof pointer.

Tier: sonnet (1), haiku (2).

### Phase 5 — Runtime-intrinsic registries (R20: 61 → 0, R21: 59 → 0)

1. `invoke.jl`: the `name === :x` arms become `INVOKE_INTRINSICS::Dict{Symbol, Function}` — dart's
   `MemberIntrinsic` enum + `_lookup`; the existing `_compile_invoke_str_*_b` builders are the
   values; `compile_invoke!` becomes a funnel: registry → devirtualized direct call → generic.
   Unknown symbol with an intrinsic pragma ⇒ loud.
2. `statements.jl`: the foreigncall arms become `FOREIGN_LOWERINGS::Dict{Symbol, Function}` —
   dart's external-member model (`functions.dart:90-189`); `compile_foreigncall!` becomes a funnel;
   unknown ⇒ `record_unsupported!` (already the default).
3. Both funnels lock at the visitor shape (≤ ~60 lines each; registry bodies may be any size).

Exit: R20 = R21 = 0 → locks. Verify: probe byte-identity (pure restructuring) + `WT_PHASE` on the
string phases (15/71/73) and STRESS-1004. Tier: sonnet for the funnel + registry skeleton, haiku for
moving bodies.

### Phase 6 — Two-tier diagnostics and correct-or-loud completion

1. Root-fix `setfield!`: cast the **value** to the field's concrete type when it arrives as `AnyRef`
   (calls.jl:3663-3666) — the MOI crash; differential test + lock.
2. `readline(stdin)` and `eval`: the crash sites are internal-tier `StackImbalanceError`s reached
   where a user-tier `record_unsupported!` belongs; classify them at the boundary.
3. `test/capability_negative_controls.jl`: all 10 controls locked to "classified diagnostic, never an
   internal error" (lock: zero `StackImbalanceError` escapes in the control suite).
4. `:splatnew` / `:copyast`: loud reject in `compile_statement!`'s default, or a lowering with a test.
5. Seed of roadmap item 2: a pre-codegen visitor over the closed-world plan
   (`wasm_library_checks.dart`-shaped) that classifies host imports / foreign calls / required
   features into a capability manifest — the structured tier reporting **call chains**, not generic
   failures.

Tier: sonnet (1, 2, 5); haiku (3, 4).

### Phase 7 — Public surface, dart `wasm_builder`-shaped

1. Export `WasmValType` and the builder API Therapy reaches for (`add_type`, `add_table`,
   `add_elem_segment`, `FuncType`, `FuncRef`, `register_vector_type!`, `encode_leb128_unsigned`) as
   a deliberate builder surface; document `Bridge` as public.
2. The undocumented zero-use exports go (2g); documented API stays.

Exit: downstream CI (Therapy/WasmMakie/Snapshot) green; ExplicitImports green.

### Phase 8 — Capability canaries (roadmap item 1), each a differential test

1. Move the `ODEProblem`/`isinplace` construction overlay from the SimpleDiffEq ext to a
   **SciMLBase-keyed** ext (one path; both solvers inherit it). OrdinaryDiffEq construction flips;
   the Tsit5 solve wall behind it is then measured and its first edge recorded with provenance.
2. Adaptive `SimpleATsit5`: one entry in `_is_typelevel_foldable` for `apply_type(Pairs, …)` over a
   concrete NamedTuple; differential.
3. Differential-verify `saveat` / interpolation / callbacks; they become canary tests.
4. MOI construction after 6.1; the next edge (`jl_clock_now`, a classified host capability) is
   recorded, not worked around.

Exit: `test/canaries/*.jl` with recorded first edges; `test/fuzz/STDLIB_COVERAGE.md` updated from
measurement.

### Phase 9 — Close

Promote every ratchet at 0 to a lock; refresh the audit stamp in `dev/PARITY_MASTER.md` and the
changed rows of `dev/CERTIFICATION.md`; the PR is ready. **Deferred to the first build on the clean
foundation**: roadmap item 4 (the normalized frontend — its type-lattice join rules must travel with
it), item 3 (sidecar), item 5 (UnifiedIR).

## 5. Verification contract

| Lane | Command | Cost | Use |
|---|---|---|---|
| structure | `julia --project=. test/parity_ratchet.jl` | 3 s | every edit |
| behavior (curated) | `julia --project=. test/smoke.jl [group]` | 14 s | every edit |
| byte identity | `julia --project=. test/probe_bytes.jl` | ~10 s | every pure restructuring |
| family | `WT_PHASE=<name> julia --project=. test/runtests.jl` | ≤ 90 s | the family touched |
| commit | `WT_SHARD=0,4 …` + the touched family's shard | 5–8 min | before each commit |
| PR | CI matrix | 18–46 min | the authoritative full gate |

Rules: pure restructuring must be byte-identical; semantic unification must be differential with its
cases added to smoke; every new lock is negative-tested before it counts; a ratchet never loosens.

## 6. Agent protocol (from the P0 lessons)

One march branch. Cheap agents get mechanical briefs with exact lines and the verification commands;
no tree-modifying git commands; the orchestrator reviews every diff and commits each verified item
immediately; every enforcement thunk is negative-tested; hygiene checks are verified with **all**
extension parents loaded; a self-qualified or oddly-shaped construct is assumed load-bearing until
its scope is read (the `optimize` kwarg shadowing incident).
