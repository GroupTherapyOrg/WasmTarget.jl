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
3. Gate (Dale's speed directive 2026-07-01): ratchet + smoke (~30s total) EVERY commit,
   targeted backfills when touching their area; the full capped gate
   (`WT_TEST_CONCURRENCY=2 julia --project=. -e 'using Pkg; Pkg.test()'`) runs ONCE per
   M-phase, at its completion boundary — not per batch. Per-commit history keeps any
   phase-gate failure bisectable.
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

- **✅ M2 — THE WRAP CHANNEL: COMPLETE (2026-07-01, certified by its full capped gate — 10
  shards 2,681/2,681 + fuzz 293/293).** The wrap chokepoint (`emit_value!(b,val,ctx,expected)`)
  is installed and is THE path everywhere a type is consumed: post-emission re-guessing DEAD
  (R4=0, LOCK L4 — `infer_value_wasm_type` gone, pre-emit deciders → `static_wasm_type` w/
  contract); returns (`emit_return_coerced!`) + phi stores (`emit_phi_local_set!` 366→36,
  stackified clusters) + field/arg stores all emit-typed through `convert_type!`; byte-scanners
  read their producers' types; `_seed_builder_locals!` makes emission types truthful (locals
  known); the ONE box emitter declares its true stack effect. En-route correctness fixes: the
  externref-store silent VALUE DROP, the return ConcreteRef null-drop, the double
  extern-convert, the unsigned-LEB ref.cast bridge. R1 219→~38 · R2 581→~244 · R7 157→~137
  ratchet into M4 (god-fn decomposition). Original plan: dart anchors:
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
  the funnel). Collapses the F3 stopgap analysis passes — delete as reached.
  **EXIT (honest revision 2026-07-01):** the wrap chokepoint installed and THE path everywhere
  a type is CONSUMED — post-emission re-guessing DEAD (R4=0 → LOCK L4; `infer_value_wasm_type`
  gone, the ~10 legit pre-emit deciders renamed `static_wasm_type` w/ pre-emit-ONLY contract =
  dart intrinsics.dart:333); returns/phi-stores/field-stores/arg-coercions emit-typed through
  `convert_type!`; byte-scanners read their producers' types. **R1/R2/R7 stay RATCHETS into
  M4**: the residual untyped sites live inside the bytes-RETURNING god-functions — typing them
  IS M4's builder-native decomposition (a strict builder cannot accept raw splices); R7's
  remainder is dominantly intrinsic implementations whose lock lands with the dart-style typed
  intrinsics table (M4). R3 (`infer_value_type`) is RECLASSIFIED, not deleted: dart's
  `node.getStaticType` equivalent — consolidate + contract-document in M4.

- **✅ M3 — ONE DYNAMIC REP: COMPLETE (2026-07-01, phase gate green — 10 shards incl.
  shard-7 re-run 515/515 + fuzz 293/293).** (a) tagged-union wrapper family DELETED + L5
  LOCKED (unions.jl 156→91; the runtests assertion that pinned the vestige now asserts
  !isdefined). (b) dart's dense-range isa: `emit_classid_range_check!` (values.jl) = the
  3-instruction unsigned window; PRE-EXISTING find: strings lack the $JlBase classId header →
  xfail strings_lack_classid (fix = class the string rep, M6/strings). (c) ZERO placeholder
  headers remain — all 15 typeId=0 sites push real classIds. Original plan: dart anchors: `translator.dart:855-870`,
  `class_info.dart:547-562`, `dynamic_forwarders.dart:250-259`. (a) Delete the union vestiges:
  the 4 dead `needs_tagged_union` branches, `emit_wrap/unwrap_union_value` adapters, the
  `{typeId,tag,value}` struct + tag_map (census: rep already retired — this is deletion, not
  redesign). (b) Abstract-type isa/typeof → dart's dense-range check (`i32.sub; i32.le_u`)
  over the existing `type_ranges`. (c) classId-0 completeness (size tuples/Vector headers).
  EXIT LOCKS: R9=0; abstract isa emits range checks; unions.jl reduced to re-exports or gone.

- **🟢 M4 — VALID BY CONSTRUCTION: CORE DELIVERED + CERTIFIED (2026-07-01 phase gate: full
  corpus, external validation OFF, zero failures).** Strict default ON (certified pre-flip by a
  dedicated full gate under WT_BUILDER_STRICT=1) · ALL ~315 explicit opt-outs removed (R6=0 →
  L6) · mod threaded into ~330 builders (full lattice gates every emission; closes Loop A's
  deferred remainder) · wasm-tools DEMOTED to opt-in `WT_VALIDATE=1` (L7 — which caught
  optimize()'s straggler default on its first run). SEVEN LOCKS. REMAINING TAIL (keeps M4
  open): god-fn builder-native decomposition — R1=~38, R2=~244 → 0 + the dart-style intrinsics
  table. Original plan: dart anchors:
  `instructions.dart:98-294`, `intrinsics.dart:28-71`. Make compile_call/compile_invoke/
  compile_new BUILDER-NATIVE (bytes-returning today — home of ALL residual R1/R2 sites + the
  R7 intrinsic ops; carve intrinsic arms into a dart-style typed table; R1=0/R2=0/R7-lock land
  here by construction). Then thread `mod` through remaining builders (full subtype lattice
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

---

# THE SECOND MARCH — the object model (branch `wt-parity-object-model`, started 2026-07-02)

The certified gaps of `dev/CERTIFICATION.md` §gaps, in dependency order. Scope boundary §5
still governs (NO ffi/async/reified-generics/threads).

## M8 — THE DISPATCH TABLE ✅ COMPLETE (2026-07-03, LOCK L10 green, boundary gate 10 shards + fuzz)

Delivered: selector registry (M8.1) · the dart virtual call classId+offset+call_indirect
through ONE flat table, E2E-proven (M8.2) · the multi-axis cascade — Julia multiple dispatch
as composed dart hops, E2E [21,22,51,52] (M8.3) · the FNV apparatus DELETED, dispatch.jl
1365→~290L, overlays = rows not parallel tables, LOCK L10_no_fnv_dispatch (M8.4). Phases
24/34 test zombies rewritten to pin the selector reality. Strings-axis exception stands
until M9.

(original design:)

**dart invariant:** ONE flat funcref table for the whole module. A selector (method name)
gets an OFFSET via first-fit packing (sort weight = classIds.length*10+callCount, desc);
a virtual call is `receiver.classId + selector.offset → call_indirect(selector.signature)`.
Monomorphic selectors (targetCount==1) never enter the table — DIRECT call. needsDispatch =
callCount>0 && targetCount>1.

**WT disease (the deletion target):** PURE-9060/9062 — per-function FNV-1a HASH tables
(≥9 uniform-arity specializations), keyed on the FULL argtype tuple, linear probing,
keys/values/typeids i32-array globals, per-table funcref tables, per-entry anyref wrappers,
a JSON serialization side-channel, and — the structural crime — `find_dispatch_call` scans
each function body and REPLACES THE WHOLE BODY with a probe loop
(`generate_dispatch_caller_body`, compile.jl:1713-1717). Overlays get a PARALLEL table
apparatus checked before the base table.

**Julia adaptation (multiple dispatch, honestly):** a selector = (generic function, arity).
The DISPATCH AXIS = the first arg position whose registered specializations vary. Targets =
Dict{classId(axis arg) → target}. Multi-axis selectors CASCADE: the axis-1 row target is a
per-class trampoline dispatching axis-2 through the SAME mechanism (still the one table).
Overlay methods MERGE into the selector's rows by Julia specificity — the parallel overlay
tables die. Row miss = trap (the honest MethodError analog; loud, dart-legit posture).

**Slices:** M8.1 SelectorInfo build (metadata only) + monomorphic devirtualization ·
M8.2 the ONE table + first-fit packing + classId+offset caller bodies (single-axis) ·
M8.3 the multi-axis cascade + overlay merge · M8.4 DELETE the FNV apparatus → LOCK
`L10_no_fnv_dispatch`. Full capped gate at M8.4. Strings can't dispatch via classId until M9
(documented exception: string-axis selectors keep direct/reject).

## M9 — STRINGS JOIN THE CLASSID WORLD ✅ COMPLETE (2026-07-03, boundary gate 10 shards + fuzz green)

Delivered: $JlString{classId, data} <: $JlBase (types.jl get_string_struct_type!); String +
Symbol flipped at every mapper incl. the builder-layer abstract rep; constants + every
producing foreigncall wrap at birth through the ONE producer; convert_type! string arms =
the migration engine (classed→data / array→wrapped); ops read .data once at entry; strings
in the DFS hierarchy → isa AbstractString = the dense-range check (xfail PROMOTED, M8's
strings-axis exception REMOVED). The str_char pre-push scratch-juggle is the flagged M11
seam.

(original design:)

Strings are bare `array<i32>` refs with no `$JlBase` header → invisible to classed isa +
the M8 table. Re-rep as a classed struct (classId + data array). Promotes the
`strings_lack_classid` xfail; removes M8's exception. BIG blast radius → full capped gate.

## M10 — SHARED CONTEXT STRUCTS (dart closures.dart:970-1013)

The escaping `Core.Box`: parent scalar-replaces while the closure mutates the real cell —
two copies. dart materializes ONE Context struct; no scalar replacement across an escaping
closure; parent reads/writes go through the same cell the closure captured. Promotes the two
`F3_mutable_capture` xfails.

## M11 — GOD-FN DECOMPOSITION + THE TYPED INTRINSICS TABLE (dart intrinsics.dart:28-71)

`compile_call`/`compile_invoke`/`compile_new` become builder-native; the annotated god-fn
seams (L9) disappear; the dart-style intrinsics table lands. Ratchets R2 (~244) + R7 (~137)
+ R3/R5 → 0 → LOCKS.

## M11 — IN FULL (Dale's directive 2026-07-03: "the single largest WIN — take it on headfirst")

**The end-state:** compile_call / compile_invoke / compile_new rebuilt BUILDER-NATIVE —
dart's code_generator.dart shape: per-expression-kind typed emitters writing into ONE
builder, returning their ValueType; the declarative intrinsics table (intrinsics.dart:28-71)
for numeric ops; ZERO bytes-returning interiors. Ratchets R2 (emit_raw seams) and R7 (raw
coercion ops) → 0 → LOCKS. This is the largest remaining structural delta; multi-session;
monotonic per-commit ratchet progress; never regressable.

**The mechanical lever:** most seams have the shape
`b = InstrBuilder(); …typed ops…; return builder_code(b)` + caller `emit_raw!(parent, …)`.
Conversion = pass the PARENT builder in; delete the local builder + the splice. Family-by-
family with the smoke/battery gate per batch. The HARD residue: byte-sniffing arms
(stmt_bytes[end] checks) and the pre-push-args pattern (args stacked before the emitter
runs — forces scratch juggles like M9's str_char); those get real redesign, not regex.

**Slices:**
- M11.1 THE INTRINSICS TABLE: `(lhsT, rhsT, op) → typed-emitter` Dict, dart-shaped; the
  numeric if-elseif chains in calls.jl route through it. R7 falls with it.
- M11.2 compile_call → `compile_call!(b, …)::WasmValType` builder-native; arms migrate in
  clusters (R2 down per commit); the bytes shell shrinks to deletion.
- M11.3 compile_invoke same (the str_* emitters already build typed — they just need the
  parent builder instead of own-builder+bytes-return).
- M11.4 compile_new + the foreigncall arms in statements.jl.
- M11.5 R3/R5 static-query consolidation; R2/R7 → 0 → LOCKS L11_no_raw_seams /
  L12_one_coercion_surface; R11 sediment sweep; the FRESH end-to-end certification
  re-audit against the dart source closes the campaign.

## M11 STATUS (2026-07-03, the overnight march)

DELIVERED: **M11.1** the dart intrinsics table (intrinsics_table.jl — declarative
(lhsT,rhsT,op)→emission, 51-entry numeric core; shifts excluded: Julia's amounts vary in
width, dart's ints don't). **M11.2a** THE TABLE ROUTE live ahead of the is_func chain with
narrow-pair normalization carried in (two near-miscompiles caught by the backfills: the
normalization bypass and the Float32 width flag); dead arms DELETED (add/sub/mul else-halves,
six int compares, four float compares). **M11.3a/b** seam batches: defaults + conditions +
phi-store fronts go builder-native (R2 233→213, monotone, baseline tightened each step).
**M11.4a** both stackified phi-store clusters ALWAYS store (the ty===nothing skip orphaned
stack values — a silent stack-corruption class).

HONEST REMAINDER (ratcheted, monotone, never regressable): R2 at 213 — the 68 driver-level
seams (whole-statement/block splices) die with the full compile_statement/compile_invoke
builder-native decomposition (M11.2b-.4 continue); R7 at 131 (the intrinsic-implementation
floor — falls with the coercion arms' migration); the escaping-closure cross-function store
(@test_broken in m10_contexts.jl) sits in the same driver-store unification. R3/R5 hold at
their floors. The locks L1-L10 all green.

### M11 SECOND ARC (2026-07-03, the completion night)

**THE DRIVER FRONTS + LOCK L11.** Every driver-level byte splice now flows through exactly
one declared front per producer — `compile_statement!`, `generate_stackified_flow!`,
`generate_branch_split_try!`, `_compile_catch_region!`, `emit_phi_local_set!`,
`compile_condition_to_i32!`, `emit_type_id!`, `_emit_throw_error_struct!` — the dart
single-entry pattern (one code generator, one builder, one boundary). **Lock
`L11_driver_fronts`** machine-enforces it: no raw driver splice at a call site can ever
return. R2 fell **233 → 143** across the two arcs, baseline tightened at every step.

**The boundary-contract truth.** Every remaining seam carries a declared stack contract
(`emit_raw!`'s pops/pushes model — the default IS declared-balanced, which region splices
truly are; value producers declare their push). The strict validator's stack model is
total: no byte enters a builder without a boundary type. What remains ratcheted at 143 is
the *interior* opacity of the god-fn emitters — dissolved emitter-by-emitter as
compile_call/compile_invoke/compile_new convert; each conversion shrinks R2 monotonically
and can never regress (the ratchet + L11 guarantee the direction).

**R7 = the honest floor.** The 131 coercion opcodes are the intrinsic *implementations*
(sext/trunc/fptosi conversion arms carrying Julia's narrow-width renormalization
semantics — Julia has 8/16/32/64-bit ints where dart has one; a uniform table CANNOT
express them, proven twice tonight by the shift exclusions). They are dart's analog of the
conversion visitors in code_generator.dart — typed, builder-native, differentially green.

**Found-and-fixed en route (the enforcement working on its author):** two INCOMPLETE
struct.get emissions (prefix+opcode, no immediates — latent invalid wasm on unregistered
structs) became loud rejects; three regex-induced self-recursions caught by smoke before
commit (one after — reverted within minutes, root-caused, the lesson re-learned: smoke
BEFORE commit, no exceptions).

## MARCH 3 — THE GOD-FN INTERIOR CONVERSION (2026-07-03/04, branch `wt-parity-march3`)

**R2: 143 → 18, LOCK L12 flipped.** The overnight march that converted the god-fn
interior splice mass to typed emission, audit-first.

**THE MECHANISM (`append_builder!`):** builders record their seeds; the typed merge
replays a fragment's REAL tracked effect at the ir/ layer — human-declared pops/pushes
lies are impossible at converted seams. Landed with `struct_new!(b, type_idx)`
(mod-resolved field lists — the empty-list fudge that phantom-tracked every constant's
operands is dead REPO-WIDE) and zero-byte splices recording no instruction.

**THE METHOD (audit-first):** permanent `WT_AUDIT_VALUE_STACK` hooks in
compile_value_typed + compile_phi_value enumerate every model liar; the channel
inversions flipped only after the audit read ZERO across smoke + the heaviest shards.
The order lesson (interiors before channel inversions) was proven three times by
one-line wat diffs and is documented at every guarded site.

**DEAD BYTE-SCANNING (the disease this march existed to kill):** ~17 LEB-decode walks
and ~25 first-byte sniffs deleted across compile_new's field weave, Core.tuple args,
memoryrefset!/push!/setindex! value channels, the struct-constant branch, PiNode's
multi-value scan, the isa DFS blocks, and the extern bridges — every decision now reads
the TRACKED TYPE dart carries with every value.

**FIXED EN ROUTE:** the escaping closure CLOSED (M10b: checked casts carry their target
type per code_generator.dart:3100 + the identity-convert double-emission); the
throw-arm-past-the-leave silent miscompile (dispatch to the stackified driver — ONE
lowering); two latent outer-scope boxing bugs (push!/setindex! boxed ReturnNode-scope
variables); a latent double extern-convert; the phantom +1 declares in the struct
field/replaced paths. FINDING pinned (@test_broken): isa over Any[] vs locally-defined
abstract hierarchies silently false — the DFS range misses Main-defined hierarchies.

**LOCK L12_god_fn_seams_only (the march's exit):** every remaining emit_raw! (15 real
sites) is a machine-verified annotated god-fn seam or front — the four god-fn junctions,
compile_statement's products + accumulator exit, the condition/try_catch products, the
narrow channel, three fronts. The class is CLOSED to new members; R2 falls only by
killing seams.

**THE REMAINDER (the next march, M4 tail):** the arm-by-arm god-fn decomposition —
compile_call/compile_invoke/compile_new/compile_statement builder-native (the
pre-pushed-args pattern dies; dart visitors emit their own args), which dissolves the
fronts + junctions (R2 18 → 0), kills the stackifier's drop byte-sniff via real tracked
heights, then R3 (136) to its floor and the fresh dart certification re-audit.

## MARCH 4 — THE GOD-FN DECOMPOSITION COMPLETE: R2 = 0, LOCK L13 (2026-07-04, branch `wt-parity-march4`)

**THE BYTE-BRIDGE CLASS IS EXTINCT.** Zero `emit_raw!` call sites exist in the codebase —
every emission is a typed builder method or a machine-tracked merge (`append_builder!`).
LOCK `L13_no_byte_bridges` holds it at zero forever.

**THE VISITORS (dart code_generator.dart:39 — `CodeGenerator extends
ExpressionVisitor1<w.ValueType, w.ValueType>`, `wrap` = accept1 + convertType, verified in
the SDK at close):** `compile_call!` / `compile_invoke!` / `compile_new!` /
`compile_foreigncall!` / `compile_statement!` / `compile_condition_to_i32!` ARE the
implementations — they emit INTO the caller's builder exactly as dart visitors emit into
the function's instruction stream; `emit_value!`/`convert_type!` are `wrap`/`convertType`.
The try/catch generator family (10 functions) returns builders. Bytes shells remain only
as one-line delegations for the dwindling byte-era remainder.

**THE FRAGMENT PATTERN** (invoke 2.6k lines, call 4.8k lines, statement 1.4k lines): the
`bytes` accumulator becomes a tracked fragment builder with EXACT discard semantics;
returns merge typed. Byte SURGERY extinct: phantom pop-twos and ref-pops became
don't-merge decisions; the unary-negation prepend is fragment composition; `resize!`
truncation is a node pop.

**THE BYTE-SCAN DISEASE IS DEAD** (~40 more scans this march): every LEB decode, first/
last-byte gate, opcode-range heuristic, GC_PREFIX hunt, and the stackifier's DROP sniff
now read node kinds and tracked types (`InstrIR.LocalGet.idx`, `StructGet.idx/.field`,
`ArrayGet.op`, `NumOp.op`, stack heights). Entire misparse classes (PURE-306/323/6005/
6006/6015, gap a6c6091b2a80) cannot exist at the ir/ layer.

**Found by the gates en route:** the sweep-latent `emit_int128_sle!/ule!` UndefVar (fuzz-
caught — only reachable on Int128-compare paths; all 20 family forms statically verified).

**R3 RECLASSIFIED** (per the M2 endgame decision): `infer_value_type` is dart's
`node.getStaticType` equivalent — legitimate pre-emit type knowledge (post-emission
re-guessing stays dead via L4). The ratchet keeps it monotone for consolidation.

**Certification anchors re-verified in the SDK at close:** code_generator.dart:39
(the visitor class shape), the `wrap`/`convertType` pair, visitStaticInvocation:1775
(intrinsics-first + visitor-emitted args — WT's intrinsics table + fragment args),
visitAsExpression:3100 (checked casts, march 3), dispatch_table.dart (M8),
intrinsics.dart:28-71 (M11), closures.dart:960-1013 (M10).

**Remaining (the standing next phase):** R7@130 (the proven intrinsic floor), R11 sediment,
the pinned @test_broken (isa over Any[] vs Main-defined hierarchies), the bytes shells'
final deletion as their callers convert, R5/R3 consolidation floors.

# ═══════════════════════════════════════════════════════════════════
# CERTIFICATION CENSUS 2026-07-04 — the fresh full-dimension audit
# ═══════════════════════════════════════════════════════════════════

Instrument: 6 parallel auditors + self-audit, every claim verified in BOTH sources
(dart = /Users/daleblack/Documents/sdk/pkg/dart2wasm, WT = src/), doc claims
re-verified in code. Baseline: the 2026-06-30 census scored ~25-30%.

## THE NUMBER: ~55/100 structural parity (15-dim mean; was ~25-30)

| # | dimension | score | one-line verdict |
|---|-----------|-------|------------------|
| 14 | instruction builder (wasm_builder) | **88** | 3-layer ir/builder/serialize faithfully reproduced; validation STRONGER than dart (always-on vs assert-gated) |
| 6 | dynamic (uninferred) calls | **78** | loud-reject = the architecturally correct Julia answer; the closed-union classId switch mirrors the forwarder core |
| 11 | records/tuples | **75** | per-concrete-Tuple struct w/ typeId ≡ dart per-shape record class; divergences monomorphization-justified |
| 12 | value boxing + strings | **72** | box/unbox byte-faithful to convertType; BUT numeric boxes don't subtype $JlBase (see F1) |
| 2 | translator/type mapping | **70** | funnel real (translateType/convertType equivalents); nullability not first-class, funnel not single-path |
| 15 | compilation driver (functions/globals) | **70** | worklist tree-shaking ethos matches; allocation-gated compile + lazy static init absent |
| 1 | visitor architecture + coverage | **68** | visitors/dispatch/intrinsics/stackifier honest equivalents; expectedType threading PARTIAL (~27 wrap sites vs dart's 100%) |
| 5 | virtual dispatch | **60** | ONE flat table + classId+offset + first-fit faithfully replicated; threshold=9 split, no LUB sigs, dead transcription |
| 9 | exceptions | **55** | sound try/catch/throw/rethrow; void tag + $current_exn global vs dart's typed (exn,stackTrace) tag payload |
| 3 | class metadata/layout | **55** | field-0 classId + DFS ranges 1:1; flat `sub $JlBase` graph, OPEN classId universe (F2), no identity-hash |
| 4 | runtime type system | **45** | range-check isa 1:1 w/ dart; $JlType hierarchy RICHER than dart's _Type; RTI tables absent; typeassert is a NO-OP (F4) |
| 13 | JS interop | **38** | dart's whole js/ glue-gen subsystem absent by host-model design (Therapy owns glue); fixed-ABI imports instead |
| 7 | closures | **35** | no vtable/context-chain/call_ref — monomorphization-justified BUT caps first-class-function support; F3 capture typing = genuine cited mirror |
| 8 | constants | **20** | dart's dedup-into-globals architecture nearly absent; strings re-emit a NEW data segment per use (F3) |
| 10 | async/generators | **5** | entirely absent (~5000 LOC in dart); sound loud-reject; defensibly out-of-scope for single-threaded WasmGC |

## LOAD-BEARING FINDINGS (doc-vs-code corrections + rooted bugs)

**F1 — numeric boxes subtype $JlBase only via the finalization RETROFIT (CORRECTED +
FIXED, march5).** The audit's strong claim was wrong: `set_struct_supertypes!` retrofits
every plain struct to `sub $JlBase` at module finalization, so the EMITTED module was
already correct (verified in wat: boxes are `(sub 0 …)`). The REAL gap was creation-time —
during emission the strict builder couldn't use the subtype relation because it was
declared only at the end. Fixed: `get_numeric_box_type!` now declares `sub $JlBase` AT
CREATION (dart class_info.dart:288 shape), the typed-channel prerequisite.

**F2 — the isa-over-Any[] @test_broken ROOT CAUSE (pinned in code).** WT numbers classIds
from an OPEN registry snapshot: `assign_type_ids!` freezes each abstract's [low,high] one-shot
(types.jl:143-249); later registrations get `ensure_type_id!` = max+1 OUTSIDE every frozen
range (types.jl:283-295) → no covering range → isa emits const 0 (calls.jl:1548-1551).
dart numbers the CLOSED whole program once, before codegen (class_info.dart:583-690).
ONE fix (close/recompute the DFS after all types known) lifts DIM 3+4 and clears the test.

**F3 — string/heap constants are not interned.** Every string constant use appends a NEW
passive data segment (instructions.jl:756-760) + fresh allocation; dart deduplicates every
constant into ONE global (eager or lazy, constants.dart:427-476). Code-size blowup + `===`
semantics divergence (equal constants not identical in WT, identical in dart).

**F4 — typeassert/as is a silent pass-through.** calls.jl:3711-3719 never emits a check;
dart's emitAsCheck THROWS (types.dart:437-481). Masked because inference usually proves the
type — a soundness gap when it can't.

**F5 — dead parity code.** (a) The faithful M8 SelectorInfo transcription
(selector_table.jl:21-176) has ZERO callers — the LIVE packer is pack_dispatch_selectors!
on DispatchTableRegistry; PARITY_MASTER's M8 claims citing SelectorInfo cite dead code.
(b) emit_box_type_id! has 0 real callers (fully dead, not "private fallback").
(c) Stale "FNV probe" comments (dispatch.jl:49, selector_table.jl:190) — FNV is deleted;
the comments predate M8.3. All three → delete/fix.

**F6 — EH proposal correction.** dart uses the LEGACY wasm EH (try_/catch_/catch_all,
code_generator.dart:1163-1279); WT uses the NEWER try_table. The divergence runs OPPOSITE
to prior doc assumptions. WT is not "behind" here — but the payload channel is (D9.1):
dart carries (exn, stackTrace) as a TYPED tag payload; WT stashes in a mutable global
(re-entrancy-fragile; catch_all also conflates host exceptions with Julia ones, D9.2).

**F7 — stack-trace infra exists but is UNWIRED.** capture_stack import + $current_stack_trace
global exist (strings.jl:218-235, generate.jl:781-814); emit_capture_stack! has ZERO callers.

**F8 — expectedType threading is per-sink, not universal.** The 4-arg wrap chokepoint
(values.jl:813, ~27 sites) + convert_type! (21 sites) exist and are dart-anchored, but the
~277-site 3-arg path doesn't coerce, and the call-arg ladder (invoke.jl:2028-2205)
re-implements convertType's arms inline. dart: 100% of expressions through wrap.

## THE NEXT-PHASE QUEUE (ranked by leverage)

1. **Close the classId universe** (F2) — one fix, lifts 2 dims, clears the @test_broken.
2. **Box supertype** (F1) — make numeric boxes `sub $JlBase`; unblocks the typed channel.
3. **Constant interning** (F3) — dedup strings/heap constants into globals (dart constants.dart shape).
4. **Universal wrap adoption** (F8) — route the 3-arg path + the arg ladder through THE chokepoint.
5. **Typed exception tag** (D9.1/D9.2) — carry the exception as tag payload; reserve catch_all for host exns; wire stack traces (F7) or delete the dead infra.
6. **typeassert check** (F4) — emit the throwing check when inference can't prove.
7. **Dead-code deletion** (F5) + try/finally differential battery (D9.4) + async loud-reject conformance test (D10.1).
8. Multi-range classId checks, LUB dispatch signatures, threshold unification (DIM 5), tuple-per-arity sharing.

**Out-of-scope by design (documented, sound):** async/generators state machine (DIM 10),
dynamic forwarders/noSuchMethod (DIM 6 — Julia MethodError = trap), JS glue generation
(DIM 13 — Therapy owns the host boundary), masquerade classes (Julia typeof is concrete).

## MARCH 5 — the census queue executed (2026-07-05, branch `wt-parity-march5`)

| item | status |
|---|---|
| F1 box supertype | ✅ CORRECTED (retrofit existed) + FIXED at creation — boxes `sub $JlBase` from birth |
| F2 closed classId universe | ✅ `_register_reachable_ir_types!` closes the world before the ONE DFS (dart class_info.dart:583-690); $JlType hierarchy creation moved above the collector; **the pinned isa @test_broken FLIPPED to @test** |
| F4 typeassert | ✅ the CHECKED cast (dart emitAsCheck): tee → ref.test $JlBase → typeof → classId range → tag-0 throw on mismatch; statically-proven casts pass through; battery covers structs + boxed numerics |
| F3 constant interning | ✅ short strings (≤64B) → ONE immutable global each (constant array.new_fixed initializer); `===` identity + code size now dart-shaped; long strings stay inline (dart lazies those — deferred: init fns can't be added during body compile) |
| F5 dead code | ✅ M8.1 SelectorInfo transcription (6.3KB) + its test + emit_box_type_id! + stale FNV comments — deleted |
| F7 stack-trace infra | ✅ dormant PURE-9036 cluster deleted (zero callers); the rebuild is D9.1's typed tag payload |
| D9.4 try/finally battery | ✅ committed — **and it caught a real wrong-value miscompile**: nested finally inside catch, non-throwing arm (51→57): the normal path fell through the outer landing end INTO the handler; fixed with the outer-merge skip machinery in generate_nested_try_catch_2 |
| D10.1 async conformance | ✅ the loud-reject lock committed (a @spawn entry must REJECT at compile) |

**Remaining queue (unchanged ranking):** D9.1/D9.2 typed exception tag + catch_all
separation (the deep exceptions item) · F8 universal wrap adoption (the arg ladder →
THE funnel) · D9.5 try-driver family → ONE lowering (f_fin4 is exhibit N that each
driver re-derives phi handling) · multi-range classId checks · LUB dispatch signatures
· threshold unification · tuple-per-arity sharing.
