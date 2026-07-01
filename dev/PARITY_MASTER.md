# PARITY_MASTER — THE authoritative dart2wasm structural-parity campaign
**Status: LIVE (2026-07-01). Supersedes PARITY_REORIENT.md, PARITY_LOOP.md, and every loop
label that predates it (Loop 0/A/B/B′/C/D/E, F-i…F-iv, B0–B4, U1–U4). Those docs remain as
reference/history only. If any doc, task queue, or memory contradicts this one, THIS ONE WINS.**

Produced by the 2026-07-01 full-scale re-audit: three deep sweeps — the WT structural-disease
census, the dart2wasm invariant map D1–D12 verified against `/Users/daleblack/Documents/sdk`,
and the plan/gate inventory. Baselines measured on commit `d385bf8`.

---

## 0. MISSION + KPI (verbatim intent)

Make WasmTarget.jl **structurally identical to dart2wasm's approach** — same guarantees, same
clean single-path structure — while remaining correct against the Julia oracle. **The KPI is
guarantees + structure, NOT coverage.** What main already compiles must keep compiling
(soundness gate), and more coverage is a welcome side effect — never the driver. At the end
there is no misleading or wrong path left: every value typed at emission, every coercion
through one funnel, one dynamic-value representation, one control-flow lowering, every failure
loud, and the module **valid by construction** (the builder proves it; `wasm-tools` becomes an
external double-check, not the gate).

Two gates, never substituted (rule #0):
- **SOUNDNESS** = differential native-vs-wasm + full `Pkg.test` (+ fuzz). "Is it correct?"
- **PARITY** = the dart2wasm source. "Is it structurally dart?" A passing test is SOUND, not
  dart-faithful. Nothing is "done" until its LOCK (§3) is green.

## 1. THE FIVE LOAD-BEARING INVARIANTS (dart, evidence-verified) → WT status

Re-read the dart anchor at the TOP of every loop — protocol step 1, not optional.

| # | dart invariant | dart anchor | WT today (census 2026-07-01) |
|---|---|---|---|
| I1 | **Validating builder**: instruction builder = type-checking abstract interpreter; subtype-checked push/pop on every emit; throws `ValidationError` w/ emit-site trace (233 verify sites) | `wasm_builder/src/builder/instructions.dart:98-294` (`_checkStackTypes` :252) | Machinery EXISTS (735-line `src/builder/validator.jl`) but runs in collect mode and NEVER gates: 341/369 builders `strict=false`, **0** `strict=true`; prod soundness rests on external `wasm-tools` (default-on in `compile()`, WasmTarget.jl:95/384-414). NB: `compile_function(;strict=true)` is a DIFFERENT, unrelated "strict" (loud-reject diagnostics, default ON) — disambiguate in code |
| I2 | **Typed expression channel**: every expression emission returns its `w.ValueType` through ONE chokepoint `wrap(node, expected)` = emit → actual type → `convertType` → expected. Types are byproducts of emission, NEVER re-derived | `code_generator.dart:39` (`ExpressionVisitor1<w.ValueType,w.ValueType>`), `:879-888` (`wrap`) | Half-migrated. Typed channel EXISTS and is dart-true (`compile_value_typed` values.jl:658 reads the type off the validator's actual stack effect; `emit_value!` values.jl:673; 196 callers) BUT untyped `compile_value` still has **219** callers returning bare bytes, papered over by **≈400 re-guess sites**: `infer_value_type` 136, `get_concrete_wasm_type` 120, `julia_to_wasm_type_concrete` 85, `infer_value_wasm_type` 61 — plus **581** `emit_raw!` byte-bridges |
| I3 | **One coercion funnel**: `convertType` = the single (~65-site) gate for ALL boundary adjustment (identity/drop/non-null/cast/box/unbox + loud throw). Boxing exists ONLY here | `translator.dart:828-875` | Box producer/consumer/discriminator single-sourced ✅ (2026-06-30). Numeric coercion has NO funnel: i32↔i64/f64 ladders open-coded per site (`I32_WRAP_I64` ×73, `I64_EXTEND_I32_S` ×33, F64 conv/promote ×24) in BOTH `compile_call` and `compile_invoke` via throwaway builders |
| I4 | **One type translator + DFS classIds**: sole type map (unknown ⇒ throw); DFS pre-order classIds → dense `[start,end]` subclass ranges; field 0 = classId; struct supertype chain mirrors subclassing; is-tests = range check (`i32.sub; i32.le_u`) | `translator.dart:493/516/614`, `class_info.dart:27/369/642-686`, `dynamic_forwarders.dart:250-259` | Mostly installed: one resolver, DFS `ensure_type_id!`, `$JlBase` classId@0, real classIds in boxes/dispatch/Int128 ✅. MISSING: dense-range isa for abstract types (WT has `type_ranges` but tests per-type equality); tagged-union rep confirmed RETIRED (`needs_tagged_union` returns `false` unconditionally, unions.jl:96) — only vestigial adapters left |
| I5 | **Loud failure posture**: anything unmodeled THROWS. NO guess-and-continue; only well-typed dummies in provably-dead positions | `translator.dart:614/502/872`, `code_generator.dart:145-153` (`unimplemented` = diagnostic + validating trap, never a fabricated value), `globals.dart:99` | Thin net: 40 silent `unreachable!` trap-stubs vs 6 `record_unsupported!` loud routes; ~79 "mismatch/likely dead" `ref_null` fallbacks; ~73 swallowing catches; Node-absent soft-skip; the #1 silent miscompile (filtered-fold → 0) is the emblem |

Supporting (consequences, installed by phases): **D5** one box `{classId@0,value@1}` ✅ ·
**D7** ONE flat dispatch table `table[classId+offset]`, offset packing, monomorphic direct-call
(`dispatch_table.dart:391-444`, `code_generator.dart:2072-2125`) · **D8** closures: ONE struct
`{classId,hash,context,vtable,ftype}`, context fields typed by the variable's REAL type
(`closures.dart:1030/1112-1118`, `translateTypeOfLocalVariable` translator.dart:991), lambdas
via the SAME generator (`generateLambda` code_generator.dart:716) · **D10/D11** typed
intrinsics map (`intrinsics.dart:28-71` `_binaryOperatorMap` of typed emit lambdas) +
`ConstantInstantiator` returning typed values w/ per-constant global dedup (`constants.dart:293/427`).

## 2. THE DISEASE BASELINE (census 2026-07-01, commit d385bf8)

Enforced by `test/parity_ratchet.jl` + `dev/parity_baseline.json` (§3). Shape context:
src/codegen = 45,027 lines / 27 files; god-functions `compile_call` 4,900L, `compile_invoke`
2,579L, `generate_nested_conditionals` 1,447L. Patch sediment ≈ 1,081 markers (PURE- 815),
densest exactly in the diseased files (calls 136, statements 116, conditionals 83).

| id | metric | baseline | end state |
|---|---|---|---|
| R1 | untyped `compile_value(` callers | 219 | **0** (typed channel only) |
| R2 | `emit_raw!(` byte-bridges | 581 | **0** |
| R3 | re-guess callers: `infer_value_type` | 136 | **0** (delete fn) |
| R4 | re-guess callers: `infer_value_wasm_type` | 61 | **0** (delete fn) |
| R5 | re-guess callers: `get_concrete_wasm_type` + `julia_to_wasm_type_concrete` | 205 | small locked pre-emit floor |
| R6 | `strict=false` InstrBuilder constructions | 341 | **0** (strict default ON) |
| R7 | raw numeric-coercion opcodes in codegen (wrap/extend/trunc/convert/promote/demote families) | ~151 | classified intrinsic floor, locked |
| R8 | legacy flow-generator callers (`generate_nested_conditionals` / `generate_if_then_else` / `compile_nested_if_else` / `generate_void_flow` / `generate_linear_flow`) | live | **0 — deleted** |
| R9 | union vestiges: `needs_tagged_union` + `emit_wrap_union_value`/`emit_unwrap_union_value` callers | 14 | **0 — deleted** |
| R10 | silent `unreachable!` trap-stubs (vs loud `record_unsupported!`) | 40 | **0** silent |
| R11 | patch-tag markers (PURE-/WBUILD-/CG-/TRUE-PARSE-/E2E-) | ~1081 | monotone down (root-fixes retire tags) |
| R12 | wasm-tools as compile-time gate | default-on | opt-in double-check |

Already LOCKED (regressions fail immediately): ONE box producer/consumer/discriminator
(`emit_classid_box!`/`emit_classid_unbox!`/`emit_isa_classid!`), `emit_box_type_id!` external
callers = 0, `ref_i31!` callers = 0, `countraw` == 0 for calls/invoke/statements/int128
(existing runtests gate), dead `generate_linear_flow` stays dead.

## 3. ENFORCEMENT: RATCHET → LOCK (cleanup made mechanical, not aspirational)

`test/parity_ratchet.jl` — standalone (`julia --project=. test/parity_ratchet.jl`, seconds,
exit 0/1) AND wired into `Pkg.test` shard 0. Every metric above has a precise, documented
pattern in the script:
- **Ratchet mode** (in-progress): FAIL if any count exceeds the committed baseline. When work
  drops a count, `WT_RATCHET_UPDATE=1` tightens the baseline in the SAME commit — so every
  commit either holds the line or ratchets it down; patchwork cannot silently accrete.
- **Lock mode** (completed): FAIL unless the metric equals its locked value exactly. Flipping
  ratchet→lock IS the machine-checked definition of "phase done" — no doc, task queue, or
  memory can resurrect finished work or claim unfinished work done (both failure modes
  observed in this audit: a zombie queue re-dispensing landed Loop B; a frozen ledger listing
  shipped fixes as open).

## 4. THE PHASES (M0–M7; these labels replace ALL prior labels)

Per-phase protocol, every loop, no exceptions:
1. **Re-read the dart anchor** for the invariant being installed.
2. Implement the smallest coherent slice; DELETE the patchwork it obsoletes in the same commit.
3. Gate: ratchet + smoke (`test/smoke.jl`, ~23s) every step; full
   `WT_TEST_CONCURRENCY=2 julia --project=. -e 'using Pkg; Pkg.test()'` at phase boundaries
   and for every wide-blast-radius change (the capped form ALWAYS — never unbounded).
4. Commit green with metric deltas in the message (`parity(M2): … [R2 581→512]`).

- **M0 — ENFORCEMENT HARNESS** *(this session)*: this doc + `test/parity_ratchet.jl` +
  `dev/parity_baseline.json` + runtests wiring + supersession banners + task/memory rewrite.

- **✅ M1 — ONE LOWERING: COMPLETE (2026-07-01, commits 5ec731a·5c5e67d·044afdc, L3 LOCKED,
  certified by the FULL capped gate: 10 shards 2,681/2,681 + fuzz 293/293).** All 8 legacy
  strategy names deleted (−4,850 lines; conditionals.jl 3,156→15, flow.jl 2,306→593);
  generate_structured = try/catch | single-block | THE stackifier — dart's exact shape.
  Original plan for reference:. dart shape: ONE structured lowering
  per function body (one CodeGenerator, no alternative strategy). WT: route ALL control flow
  through the stackifier (`generate_stackified_flow`, the correct path) by collapsing the
  5-clause routing heuristic (`stackified.jl:43-50`); then DELETE the legacy family —
  `generate_nested_conditionals` (1,447L, **documented multivar-phi miscompiler**,
  flow.jl:38-42), `generate_if_then_else` (401L), `compile_nested_if_else`,
  `generate_void_flow` (410L), `generate_linear_flow` (already dead). ~3–4k lines and 83+
  PURE- tags deleted BEFORE the channel migration has to touch them; conditionals.jl (3,156L,
  142 emit_raw!) largely disappears. Differential risk is byte-shape only — the stackifier
  already handles the complex shapes; full gate at the flip. EXIT LOCKS: R8=0 (family
  deleted); routing heuristic gone (one call site, no strategy choice).

- **M2 — THE WRAP CHANNEL (I2+I3 fused; the keystone)**. dart anchors:
  `code_generator.dart:879-888`, `translator.dart:828-875`, `intrinsics.dart:28-71`. Finish
  WT's `wrap`: ONE chokepoint `emit_value!(b, val, ctx, expected)::WasmValType` = emit → actual
  (already true: the type comes off the validator's stack, dart-style) → `convert_type!`
  (actual→expected, gaining the numeric arms: wrap/extend/convert/promote/demote) → expected.
  Migrate file-by-file (statements → calls → invoke → flow/stackified → generate → the rest);
  each commit: route that file's `compile_value` callers through the chokepoint, delete its
  re-guess calls (R3/R4/R5) and `emit_raw!` bridges (R2), route its open-coded coercion
  ladders through `convert_type!` (R7), **flip its builders `strict=true` in the same commit**
  (a freshly typed region must immediately self-validate — I1 rides along), and carve its
  intrinsic arms toward a dart-style typed intrinsics table (starts the god-function
  decomposition of `compile_call`/`compile_invoke`, whose duplicated coercion collapses into
  the funnel). Collapses the F3 stopgap analysis passes — delete as reached. EXIT LOCKS:
  R1=0, R2=0, R3=0 + fn deleted, R4=0 + fn deleted, R5 at locked pre-emit floor, R7 at locked
  intrinsic floor; duplicated `get_phi_edge_wasm_type` (flow.jl:268 / stackified.jl:708) = one.

- **M3 — ONE DYNAMIC REP, finished (I4 completion)**. dart anchors: `translator.dart:855-870`,
  `class_info.dart:547-562`, `dynamic_forwarders.dart:250-259`. (a) Delete the union vestiges:
  the 4 dead `needs_tagged_union` branches, `emit_wrap/unwrap_union_value` adapters, the
  `{typeId,tag,value}` struct + tag_map (census: rep already retired — this is deletion, not
  redesign). (b) Abstract-type isa/typeof → dart's dense-range check (`i32.sub; i32.le_u`)
  over the existing `type_ranges`. (c) classId-0 completeness (size tuples/Vector headers).
  EXIT LOCKS: R9=0; abstract isa emits range checks; unions.jl reduced to re-exports or gone.

- **M4 — VALID BY CONSTRUCTION, endgame (I1)**. dart anchor: `instructions.dart:98-294`.
  After M2's per-file flips: thread `mod` through remaining builders (full subtype lattice
  everywhere), make `strict=true` the DEFAULT (rename to disambiguate from
  `compile_function(;strict)`), validator THROWS with emit-site trace (dart `ValidationError`
  shape), then demote `wasm-tools` to opt-in/CI double-check. WT goes beyond dart here: dart's
  checks are assert-gated; ours stay always-on. EXIT LOCKS: R6=0; R12 demoted; full test
  corpus compiles with external validation OFF, engines accept every module.

- **M5 — LOUD FAILURE POSTURE (I5)**. dart anchors: `code_generator.dart:145-153`,
  `translator.dart:614/872`, `globals.dart:99`. Sweep guess-and-continue: the 40 silent
  `unreachable!` stubs → `record_unsupported!`-style loud reject or dart-`unimplemented`
  (diagnostic + validating trap — NEVER a fabricated typed value); `ref_null`-on-mismatch and
  zero-defaults → loud or provably-dead-only; swallowing catches audited; Node-absent
  soft-skip surfaced. CERTIFICATION CASE: `sum(x for x in xs if c)` must become correct or
  loud — never silently 0. EXIT LOCKS: R10=0 silent; fallback census locked at 0; the
  miscompile case in smoke as must-not-be-silent.

- **M6 — THE OBJECT MODEL: closures + dispatch (D7+D8; largest delta, LAST)**. dart anchors:
  `closures.dart:1030/1112-1118`, `code_generator.dart:716-729/2072-2125`,
  `dispatch_table.dart:391-444`. (a) Captured variables typed by their REAL type — the F3 join
  IS WT's `translateTypeOfLocalVariable`; typed context struct; promote the smoke xfail.
  (Census correction: `compile_closure_body` is NOT a separate pipeline — it funnels through
  shared `generate_body`; the work is capture TYPING + deduping the triplicated registration
  preludes, not deleting a path.) (b) ONE closure value `{classId, context, funcref/vtable,
  ftype}`. (c) Dispatch: ONE flat funcref table `table[classId + selector.offset]`, offset
  packing, monomorphic direct-call fast path, upper-bound signatures — replaces the FNV-hash
  scheme. EXIT LOCKS: xfail promoted; one closure rep; one registration prelude; dispatch
  emission matches dart's 4-instruction sequence (local.get / struct.get classId / i32.add
  offset / call_indirect).

- **M7 — CERTIFICATION + THE ONE PR**. Side-by-side per-invariant citation table dart ↔ WT
  (file:line both sides, I1–I5 + D5/D7/D8/D10/D11); ALL locks green; ratchet shows end-state
  numbers; full matrix (capped Pkg.test + fuzz + downstream) green; THEN the single PR to main.

## 5. SCOPE BOUNDARY (mirrors dart's own periphery)

OUT (dart layers these on top of the same core; WT excludes them from parity): async/await +
generators (async.dart, sync_star.dart, state_machine.dart, await_transformer.dart), FFI /
ccall / linear memory (ffi_native_transformer.dart), JS-interop specialization beyond WT's
existing import mechanism (dart js/ subdir), runtime reified generics, threads, finalizers,
BigInt beyond Int128, reflection/eval. IN: everything else in the 12-dimension map.
PARITY_LEDGER.md stays as the row catalogue; its STATUS column is frozen/stale — live status
exists ONLY here and in the ratchet.

## 6. LABEL TRANSLATION (history stays legible)

Loop A (lattice) → done, absorbed into I1/M4 · Loop B + F-i…iv + design-B0–B4 + the commits
mislabeled "parity(Loop C)" → landed box work under I3/D5; remainder = M3 · U1–U4 → M3(a)
(census: mostly already done) · Loop B′ → M3/M5 consumers · F3 L0–L2 → analysis kept; wiring
superseded by M2 (channel) + M6 (capture typing = the root) · Loop C → M2 · Loop D → M4+M5 ·
Loop E → M6 · ledger B1–B17/F1–F31/P1–P22 → catalogue keys only. Dead code found by the
census (`generate_linear_flow`) → deleted in M1. Commit convention: `parity(Mn): … [Rk a→b]`.
