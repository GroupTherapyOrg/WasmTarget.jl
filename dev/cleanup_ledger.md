# WasmTarget Cleanup — Phase-0 Discovery Ledger

Branch: `wt-builder-cleanup` (off `wt-wasm-builder` = PR #70, migration, do not merge yet).
Date: 2026-06-28.
Prereq DONE: the typed-InstrBuilder migration is complete + validated (`Pkg.test()` GREEN, 2679
tests / 10 shards; CI byte-identity invariant locked). See `dev/WASM_BUILDER_MIGRATION.md` +
`dev/MIGRATION_PLAYBOOK.md`.

This file is the prioritized **WORK-LIST** that drives the 6 cleanup loops in `dev/CLEANUP_LOOP.md`.

## The triple oracle (why deletion is now safe)
Every cleanup step runs all three; green on all three = the hack is gone for good.
1. **Strict model** (`WT_BUILDER_STRICT=1`) — structural/stack/type-balance breakage throws a
   `StackImbalanceError` at the emit site with the Julia statement + stack snapshot
   (`builder_diagnose`; `src/builder/instr_builder.jl:115-122` `_check!`).
2. **Full suite** (`Pkg.test()`, 2679 tests / 10 shards incl. Aqua) — behavioral regressions.
3. **Differential fuzzer** (Supposition, native Julia oracle; `test/runtests.jl:76`,
   `test/fuzz/generators.jl`) — silent value divergence.

Most cleanups are BEHAVIORAL (removing a `fix_*` pass changes output only for the fns it rewrote),
so the load-bearing oracle is suite + fuzzer; byte-identity is used only for refactors that should
not change output (Loop 2).

### The discovery instrument: `WT_NEUTRALIZE` (default-OFF env gate)
A new default-OFF env gate bypasses the `fix_*` byte-rewriters: each `fix_*` now starts with
`_wt_neutralized("<name>") && return bytes`. `WT_NEUTRALIZE=all` bypasses ALL 7 passes at once.
This complements `WT_BUILDER_STRICT`: STRICT throws where the builder emits something a `fix_*`
later corrects (pre-localizes the bug); NEUTRALIZE measures whether bypassing the post-emission
rewriter changes any bytes at all (proves the rewriter dead-on-corpus). Harness:
`test/fuzz/cleanup_neutralize_probe.sh` (PASSES array) + `test/fuzz/cleanup_probe_corpus.jl`
(56-fn probe corpus, frozen via `probe_digest`).

---

## ⭐ KEY FINDING (dynamic probe, branch `wt-builder-cleanup`)

> **All 7 `fix_*` post-emission byte-rewriters are no-ops across the 56-fn probe corpus.**

With `WT_NEUTRALIZE=all` (ALL 7 passes bypassed), recompiling the 56-function corpus — which
includes functions purpose-built to trigger *every* pass's pattern (`length()`/`v[end]`; mixed
Int32/Int64 arithmetic; consecutive + type-changing local sets; ref-producing selects/ternaries;
union/boxing number→ref local stores) — produced **ZERO changed bytes and ZERO newly-invalid
modules** vs the active-passes baseline. This reconciles with the static census: the migrated
typed InstrBuilder emits correct bytes UP FRONT, so these post-emission rewriters are provably
dead on the corpus and deletable (triple-gated, with backfilled regressions).

**Behavioral confirmation — DONE (2026-06-28): GREEN.** The full suite (10 shards / diff fuzzer /
stdlib catalogues / integration fixtures) ran under `WT_NEUTRALIZE=all` and produced **exactly ONE
failure across all shards**, at `runtests.jl:10896` — the Phase-76 subtest "a genuinely spurious
i32.wrap_i64 is still stripped", which DIRECTLY calls `fix_i32_wrap_after_i32_ops(spur)` and asserts
the byte-rewrite fires. With the pass neutralized it is a no-op, so a *self-referential unit test of
the neutralized pass* fails — NOT a codegen regression (the other two Phase-76 subtests, which assert
the pass does not corrupt operands, pass trivially). This is precisely the L1.b "pins the rewriter's
OWN behavior → deleted with the pass" case. **Conclusion: all 7 `fix_*` passes are behaviorally dead
for real codegen; the lone failure is removed when the pass + its self-test are deleted.**

<!-- SUITE: GREEN modulo runtests.jl:10896 (Phase-76 self-test of the neutralized pass; retired with fix_i32_wrap_after_i32_ops) -->

**Pre-existing failures (NOT caused by neutralization):** `p_unionvec` and `p_anyret` fail wasm
validation EVEN WITH passes active — union/Any-return gaps that no `fix_*` rescues. These are
semantic-coverage / Loop-6 "loud-reject or overlay" items, **not** structural patch-debt. See
*Side findings*.

---

## Prioritized work-list (LOW-RISK / HIGH-REDUNDANCY first — build momentum)

| # | id | kind | Loop | still_needed | removal_risk | guarding_test | one-line action |
|---|----|------|------|--------------|--------------|---------------|-----------------|
| 1 | `drop_validate_emitted_bytes` | validator | L3 | provably-dead | low | EXISTS (live `b.v` model pinned: runtests.jl:1389-1403, 4351-4453) | Delete advisory no-op scanner + orphaned `ctx.validator` field; byte- & behavior-identical by construction. |
| 2 | `fix_consecutive_local_sets` | fix_pass | L1 | provably-dead | low | NONE (backfill multi-target-phi diff) | Delete pass + 3 dead self-host call sites; already removed from prod path (WBUILD-1011/1012). |
| 3 | `fix_i32_wrap_after_i32_ops` | fix_pass | L1 | needs-suite-confirm | low | EXISTS (Phase 76 unit, runtests.jl:10871) but tests the rewriter (deleted with it) → backfill e2e | Delete pass + 4 call sites; backfill raw-byte e2e on p_i32chain/p_i64mix/p_idxi32/p_bitsi32. |
| 4 | `fix_i64_local_in_i32_ops` | fix_pass | L1 | provably-dead | low | NONE (backfill validate+numeric diff) | Delete pass + 4 call sites; front-line wrap at calls.jl:4711 subsumes it. |
| 5 | `fix_local_get_set_type_mismatch` | fix_pass | L1 | provably-dead | low | NONE (backfill i32-edge-into-i64-phi diff) | Delete pass + 4 call sites; structural widening at stackified.jl:1165-1172 replaces it. |
| 6 | `fix_broken_select_instructions` | fix_pass | L1 | provably-dead | low | NONE (backfill struct/ref-ternary + high-local-idx gcd diff) | Delete pass + 4 call sites; typed `select_t!` / typed if-block replaces it. |
| 7 | `fix_array_len_wrap` | fix_pass | L1 | needs-suite-confirm | medium | NONE (backfill byte-level strip+false-positive unit) | Delete TOGETHER with #5 (its sole introducer); migrated path widens via I64_EXTEND, never wraps. |
| 8 | `fix_numeric_to_ref_local_stores` | fix_pass | L1 | provably-dead | medium | NONE (backfill ref.null-emit golden + DROP+UNREACHABLE) | Delete pass + 4 call sites; emit-time guards stackified.jl:1186-1208 subsume it. |
| 9 | `marker_triage_pure_wbuild_cg` | marker_class | L3 | needs-suite-confirm | low | PARTIAL (Phase 76 pins one fixer; byte-peek helpers unpinned) | Terrain-map: bulk un-tag 825 doc-only; ride fix_* markers out w/ L1/L4; replace ~82 byte-peek sites in L3. |
| 10 | `return_type_compatible_lattice` | type_compat | L4 | load-bearing | high | NONE (backfill per-arm validating diffs + negative loud-reject) | DO NOT DELETE — replace predicate + 7-line coercion ladder ×10 sites with WasmGC HeapType lattice + one `coerce!`. |
| 11 | `flow_generator_dual_lowering` | flow_generator | L2 | load-bearing | high | NONE as auto-assert (manual digest harness exists, not CI-wired) | DO LAST — wire byte-identity CI, then collapse specialized lowerings into `generate_stackified_flow` shape-by-shape. |

Probe non-applicability note: items #10 and #11 are NOT covered by the `WT_NEUTRALIZE` 0-byte
result — the gate toggles only the 7 `fix_*` rewriters in `generate.jl`; the return-type predicate
and the flow generators are pre-emission and run unconditionally. Their risk is real semantic
change, not provably-dead deletion.

---

## Loop 1 — strict-on + delete the patch-debt (the 7 `fix_*` passes)

Arm `WT_BUILDER_STRICT` in CI. Delete the passes one at a time, triple-gated, each with a
backfilled regression. The `WT_NEUTRALIZE=all` probe already proved all 7 dead-on-corpus.

### L1.a `fix_consecutive_local_sets` — provably-dead · risk LOW
- **Locations:** `src/codegen/generate.jl:682` (def); `generate.jl:191-195` (WBUILD-1011 disabling
  comment — prod call already REMOVED here); `compile.jl:3229` (run_direct), `compile.jl:3380`
  (run_e2e_inlined), `compile.jl:3460` (run_selfhost) — all 3 dead self-host MVP entry points;
  `src/codegen/flow.jl:472` (`emit_phi_local_set!` — the typed-builder replacement).
- **Compensates for:** two consecutive `[0x21 idx]` (local.set) from the OLD phi codegen that
  pushed a phi value ONCE then issued local.set per target (second/third set hit empty stack).
  SET→TEE rewrite kept the value live. Disabled in commit `60a90d6` (WBUILD-1012, 2026-03-30)
  because it false-fired on genuinely-distinct adjacent sets (Int128/struct two-ref pops).
- **Source emitters:** legacy phi-edge emission — now `emit_phi_local_set!` (flow.jl:472) pushes
  each edge value before EACH local.set, so no consecutive set-set chain is produced (phi call
  sites generate.jl:2187/2253/2519/2559/2580).
- **Blast radius:** prod pipeline = NONE (call removed at generate.jl:191; 3 live sites are dead
  self-host demos compiling trivial `f(x::Int64)=x*x+1`, no phi, untested — `test/selfhost/`
  absent). Probe p_reassign = 0 byte delta.
- **Guarding test:** NONE. Backfill a multi-target-phi differential test (one SSA value flows to
  ≥2 phi locals across a merge, e.g. swap/branch-merge) asserting compile+validate+run==native, to
  lock `emit_phi_local_set!`.
- **Action:** delete `fix_consecutive_local_sets` (generate.jl:682-800) + the 3 dead call sites
  (compile.jl:3229/3380/3460); remove `consecutive_local_sets` from the neutralize harness lists.

### L1.b `fix_i32_wrap_after_i32_ops` — needs-suite-confirm · risk LOW
- **Locations:** `generate.jl:311` (def), `generate.jl:312` (neutralize gate), `generate.jl:233`
  (call site, generate_function_body); `compile.jl:3245/3392/3473` (call sites);
  `test/runtests.jl:10871-10898` (Phase 76 unit on the pass); `src/builder/validator.jl:317-318`
  (I32_WRAP_I64 validation: pop I64/push I32); `src/builder/instr_builder.jl:178`
  (num! → validate_instruction!).
- **Compensates for:** raw-byte codegen emitted `i32.wrap_i64` (0xA7) after an op already producing
  i32 (comparison result / i32 arithmetic) → `<i32-producing opcode> 0xA7` fails validation
  ("expected i64, found i32"). Also accreted defensive operand-skipping (GC immediates,
  `select_t`/if ref-blocktype where type index 167 LEB-encodes as `0xA7 0x01`) — a self-inflicted
  false-positive from an earlier raw-byte scanner walking into operands.
- **Source emitters:** statements.jl:370 `emit_pinode_narrow` (now guarded `val_wasm_type===I64`);
  calls.jl:4715 numeric-intrinsic arg coercion (now guarded `_actual_wasm===I64`);
  conditionals.jl:830/887 phi-narrowing wrap; calls.jl:7107 (after struct_get I64 — genuine i64);
  types.jl:1044 (after i64 local.get — genuine i64).
- **Blast radius:** all ~75 `num!(b,I32_WRAP_I64)` sites are now type-directed; unconditional sites
  sit after genuine I64 producers. Probe p_i32chain/p_i64mix/p_widemul/p_bitsi32/p_idxi32 →
  0 changed / 0 invalid. CAVEAT: prod runs with STRICT OFF, so the typed validator only COLLECTS
  the I64-vs-I32 mismatch (validator.jl:84-86) and does NOT throw — deadness rests on type-directed
  emitters (confirmed) + behavioral suite confirmation (pending).
- **Guarding test:** Phase 76 (runtests.jl:10871) pins the rewriter's OWN behavior (positive strip
  + select_t/if false-positive guards), NOT end-to-end codegen — it is DELETED with the pass.
  Backfill an END-TO-END regression: compile p_i32chain/p_i64mix/p_idxi32/p_bitsi32 and assert the
  RAW emitted bytes contain no `<0x45-0x78|0xD1> 0xA7` sequence AND wasm-tools validate passes.
- **Action:** confirm `WT_NEUTRALIZE=all` 2679-test run GREEN, then delete generate.jl:311-517 +
  4 call sites (generate.jl:233; compile.jl:3245/3392/3473). Optionally arm `WT_BUILDER_STRICT` in
  CI first so the I64-vs-I32 mismatch becomes a hard throw (type-directedness → enforced invariant).

### L1.c `fix_i64_local_in_i32_ops` — provably-dead · risk LOW
- **Locations:** `generate.jl:533` (def), `generate.jl:534` (neutralize guard), `generate.jl:556`
  (i64-local detection `all_local_types[idx+1]===I64`), `generate.jl:567-605` (4 insertion
  patterns), `generate.jl:228` (real call site, generate_function_bytecode); `compile.jl:3244/3391/3472`
  (MVP baked-CI E2E paths).
- **Compensates for (PURE-6027, generate.jl:519-531):** Julia inference says `is_32bit=true` (i32
  ops emitted) but the operand lives in an i64 wasm local/const (phi/SSA i64 local; Int64 literal
  in invoke arith where is_32bit came from the first arg) → `[local.get i64|i64.const][opt
  i32.const|opt local.get][0x6a..0x78 i32 binop]` with NO wrap → "expected i32, found i64". Inserts
  the missing 0xA7. Understands fixed opcode adjacency only, NOT the stack.
- **Source emitters:** calls.jl:4836-4860 (`compile_call` int-intrinsic `is_32bit?I32_ADD/...` via
  `_op1!`); calls.jl:4706 (generic-arith / numeric-intrinsic operand push).
- **Blast radius:** the migrated emitter inserts the wrap UP FRONT — `compile_call`
  (calls.jl:4711-4722) calls `get_phi_edge_wasm_type(arg,ctx)` (returns the ACTUAL allocated wasm
  local type from ctx.ssa_locals/phi_locals/locals, flow.jl:340-352 — the exact i64-local fact this
  pass reads) and when `is_32bit && actual===I64` emits `I32_WRAP_I64` immediately, before `_op1!`.
  Front-line wrap also covers non-adjacent stack shapes this pass cannot → strictly subsumed. Probe
  p_i64mix/p_widemul/p_idxi32/p_i32chain/p_bitsi32 → 0 changed / 0 invalid. The 3 compile.jl sites
  are the `f(x::Int64)=x*x+1` MVP/baked-CI demo path.
- **Guarding test:** NONE (runtests.jl:10867-10872 tests the DIFFERENT pass). Backfill a behavioral
  diff test on `f(a::Int64,b::Int32)=a+Int64(b)`, `f(a::Int32)=Int64(a)*2`,
  `f(v::Vector{Int64},i::Int32)=v[Int64(i)]` asserting wasm-tools validate passes AND result==native
  (pins the front-line `get_phi_edge_wasm_type` wrap, calls.jl:4711 standalone).
- **Action:** backfill the diff test, then delete `fix_i64_local_in_i32_ops` + all 4 call sites
  (generate.jl:228; compile.jl:3244/3391/3472). Coordinate L1 removal with its sibling
  `fix_i32_wrap_after_i32_ops` (shared front-line replacement + provably-dead status).

### L1.d `fix_local_get_set_type_mismatch` — provably-dead · risk LOW
- **Locations:** `generate.jl:986` (def), `generate.jl:216` (real call site, generate_body;
  `all_local_types` built 209-215); `compile.jl:3242/3389/3470` (self-host paths);
  `stackified.jl:650-652` + `:740-744` (`compile_phi_value` emits i32 into I64 phi, defers
  widening — PURE-313); `stackified.jl:1022` + `:1135` (`set_phi_locals_for_edge!` guards excluding
  I64/I32 from boxing); `stackified.jl:1165-1172` (`set_phi_locals_for_edge!` emits
  `I64_EXTEND_I32_S` inline — the structural widening that replaces this pass).
- **Compensates for:** adjacent `local.get X; local.set/tee Y` where stored value width (i32/i64)
  differs from destination local's declared width → "type mismatch: expected i64 got i32". Occurs
  at phi merges (one predecessor i32, merged phi local I64). Only handles the I64↔I32 pair.
- **Source emitters:** `set_phi_locals_for_edge!` (stackified.jl) phi-edge stores; `compile_phi_value`
  (stackified.jl:634+) producing the i32 value for an I64 phi (PURE-313).
- **Blast radius:** the migrated `set_phi_locals_for_edge!` reconciles STRUCTURALLY at emit time —
  stackified.jl:1165-1172 emits `I64_EXTEND_I32_S` (0xAC) inline for I64-local/I32-edge (and
  F64/F32_CONVERT for float widening), guards at 1022/1135 routing the I64/I32 pair there.
  `compile_phi_value`'s PURE-313 i32 deferral is always paired with the caller's inline extend. No
  non-phi local_set/tee emitter (256 sites) stores a width different from its local's declared type.
  Probe = 0 changed / 0 invalid.
- **Guarding test:** NONE pins THIS case. Indirect i64-phi coverage exists but is uniformly-Int64
  (runtests.jl:4831 while-sum, :4867 gcd_iter swap, :4902 collatz, :4914 bin_search) — none MERGES
  an i32 edge into an i64 phi. Backfill a `compare_julia_wasm` fn where a loop/branch phi is inferred
  I64 but one edge yields Int32 (e.g. `function(n::Int64,k::Int32); a=Int64(0); for i in 1:n; a =
  i==1 ? Int64(k) : a+i; end; a; end`), asserting Node==native AND validate passes, run with
  `WT_NEUTRALIZE` unset so the structural widening (stackified.jl:1171) is exercised.
- **Action:** delete generate.jl:986 + 4 call sites (generate.jl:216; compile.jl:3242/3389/3470),
  plus the now-unused `all_local_types` at generate.jl:209-215 IF not consumed by the sibling i64
  passes at the same site. Note compile.jl:3242/3470 also call `fix_array_len_wrap` /
  `fix_i64_local_in_i32_ops` — remove only THIS pass's line at each site.

### L1.e `fix_broken_select_instructions` — provably-dead · risk LOW
- **Locations:** `generate.jl:1285` (def), `generate.jl:1286` (neutralize gate), `generate.jl:158`
  (call in generate_body, primary prod path); `compile.jl:3227` (run_direct), `compile.jl:3378`
  (run_selfhost), `compile.jl:3458` (third MVP helper) — all test/MVP, BYPASS generate_body;
  `calls.jl:2042-2134` (the ifelse emitter it compensated for); `conditionals.jl:738`
  `compile_ternary_for_phi` (`?:` emitter — typed if-block, never select).
- **Compensates for (PURE-036y):** a malformed untyped SELECT (0x1b) for ref/struct values lacking
  an i32 condition — `[local.get, struct.new, select]`. Root cause (calls.jl:2051-2058): the OLD
  ifelse emitter classified condition ref-vs-value by BYTE-SCANNING `cond_bytes` for `0xfb 0x00/0x01`,
  colliding with LEB128 operands (`local.get 251` = `[0x20,0xfb,0x01]`) → a high-index non-ref
  condition misclassified as ref, SELECT dropped (froze gcd-style phi loops; gap family
  `6830e0e173d4` / `c8566ce342f8`). Pass scrubbed the broken bytes after the fact.
- **Source emitters:** `compile_call` ifelse branch (calls.jl:2042-2134) — now classifies condition
  by `infer_value_wasm_type` and emits typed `select_t!`.
- **Blast radius:** pattern no longer emitted — (1) ifelse emitter (calls.jl:2059-2131) classifies
  by VALUE TYPE, falls back cleanly when cond is ref (2065-2068) or any operand empty (2073-2096),
  and for ref/struct/array/String emits TYPED `select_t!` (0x1c + `0x63+sLEB type_idx`, 2114-2123) —
  never bare 0x1b after struct.new; (2) ref/struct `?:` route through `compile_ternary_for_phi`
  (conditionals.jl:738) → typed if/else/end with a result type (785); (3) remaining untyped `select!`
  emitters (int128.jl, calls.jl shift helpers ~266/276/309/3472) are value-typed with an i32
  condition, and `validate_instruction!` (validator.jl:306-314) pops the i32 — a condition-less
  select fails validation at emission, not survives to this pass. Probe p_selnum/p_selref/p_ifelse/
  p_selstruct/p_nestsel → 0 changed / 0 invalid.
- **Guarding test:** NONE asserts on the pass. Emitter coverage thin (catalogue.jl:129-130
  value-typed ifelse; runtests.jl:1781 multi_branch_ifelse Int64). Backfill `compare_julia_wasm`:
  (a) struct/string-producing ternary `b ? Pt(1,2) : Pt(3,4)` and `x>0 ? "pos":"neg"`; (b) ifelse
  over ref values; plus a gcd-style loop whose phi condition local index ≥ 128 to re-pin the
  original `0xfb`-LEB-collision infinite-loop gap.
- **Action:** add the backfill tests, confirm the `WT_NEUTRALIZE=all` run GREEN, then delete
  generate.jl:1277-1383 + 4 call sites (generate.jl:158; compile.jl:3227/3378/3458). The typed
  `select_t!` ifelse emitter is the load-bearing replacement and stays.

### L1.f `fix_array_len_wrap` — needs-suite-confirm · risk MEDIUM
- **Locations:** `generate.jl:269` (def), `generate.jl:270` (neutralize gate), `generate.jl:222`
  (primary call site, generate_body); `compile.jl:3243/3390/3471` (selfhost/baked MVP entries);
  emitter `src/builder/instr_builder.jl:382` (`array_len!`); encoder `src/builder/instr_ir.jl:239`
  (ArrayLen → `[0xFB 0x0F]`); validator `src/builder/validator.jl:678-681` (array.len pops any,
  pushes I32), `:317-318` (I32_WRAP_I64 pops I64, pushes I32); downstream widen
  `src/codegen/invoke.jl:2732-2734` (`array_len!` then `I64_EXTEND_I32_S`).
- **Compensates for:** byte pattern `[0xFB 0x0F][0xA7]` = array.len followed by i32.wrap_i64.
  array.len returns i32 but Julia `length()` is Int64; legacy codegen modeled length() as i64 and
  the per-local repair `fix_local_get_set_type_mismatch` could land an i32.wrap_i64 directly after
  array.len (pop I64 but stack top is I32). Per generate.jl:219-221 this pass MUST run AFTER
  `fix_local_get_set_type_mismatch` because that sibling is what introduces the wrap — a
  fix-pass-INDUCED artifact, not a primary-emitter artifact. Forward-parse (`_instr_next`) guards
  against 0xA7 being a LEB immediate of a preceding instruction (the E-003 fn#107 i64.mul
  regression from the old backward scan).
- **Source emitters:** `fix_local_get_set_type_mismatch` (generate.jl:216, cited as the introducer
  — a sibling post-emission pass); legacy pre-migration length()/array.len i64 codegen (gone:
  migrated path emits `I64_EXTEND_I32_S`, never `I32_WRAP_I64`, after `array_len!` — invoke.jl:2734).
- **Blast radius:** affects only modules where `[0xFB 0x0F][0xA7]` appears post-emission. No typed
  emitter follows `array_len!` with a wrap (grep of `array_len!`+2 lines for wrap is empty; all 14
  invoke.jl sites widen via `I64_EXTEND_I32_S`). Probe p_len/p_end/p_lenarith/p_lastidx/p_sizeloop →
  0 changed / 0 invalid. **RESIDUAL RISK = the cross-pass interaction:** the wrap is only ever
  introduced by `fix_local_get_set_type_mismatch`, so this pass is dead UNLESS that sibling still
  produces it. If `fix_array_len_wrap` is deleted while the sibling is kept and can still emit a
  wrap after array.len, validation could regress — **delete-order matters: retire both together.**
  Under `WT_BUILDER_STRICT`, a typed wrap-after-len throws `StackImbalanceError` at emit
  (instr_builder.jl:116-119), so the typed path structurally cannot reach the pattern.
- **Guarding test:** NONE. Backfill (1) a byte-level unit test mirroring runtests.jl:10872's pattern
  for the sibling: feed `[array.len, i32.wrap_i64]` and assert the wrap is stripped, AND feed a
  false-positive (`local.get 2043` = `[0x20 0xFB 0x0F]` then a LIVE i32.wrap_i64, plus a type-index
  operand `0xA7 0x01`) and assert it is preserved (pins the E-003 fn#107 forward-parse fix); (2)
  e2e length() is already differentially pinned (catalogue.jl:159 `add(:length,(Vector{T},),Int64)`
  over all T; exercised in cleanup_probe_corpus.jl:18-22) but neither asserts THIS pass's byte
  rewrite.
- **Action:** treat as provably-dead-on-corpus but hold deletion until (a) the `WT_NEUTRALIZE=all`
  full-suite run confirms behavioral GREEN, and (b) the coupled sibling
  `fix_local_get_set_type_mismatch` (sole documented introducer) is itself proven dead/deleted in
  the same loop step — **these two retire together.** Backfill the byte-level unit (strip genuine
  wrap + preserve false-positive operand 0xA7) before removal so the E-003 forward-parse guarantee
  and the cross-pass invariant are pinned. Lowest-risk next step: add the unit test now (passes
  against current code), then delete both passes and re-run the probe corpus + catalogue length
  differentials.

### L1.g `fix_numeric_to_ref_local_stores` — provably-dead · risk MEDIUM
- **Locations:** `generate.jl:1397` (def), `generate.jl:1398` (neutralize gate),
  `generate.jl:1459-1467` (struct.new→numeric-opcode DROP+UNREACHABLE sub-rule),
  `generate.jl:1514-1586` (i32/i64.const→local.set ref-local core rewrite), `generate.jl:167`
  (production call site); `compile.jl:3228/3379/3459` (run_e2e_inlined / run_selfhost MVP harnesses);
  `stackified.jl:1186-1208` (emit-time guard that subsumes it); `stackified.jl:596-624`
  (`emit_phi_type_default` → ref.null); `test/fuzz/cleanup_probe_corpus.jl:41-43`
  (triggers p_union/p_unionvec/p_anyret).
- **Compensates for (PURE-6025, generate.jl:160-167):** a type-confused store of a numeric constant
  into a ref-typed local — inference reports a phi/SSA value as a ref type (e.g.
  `Union{ConcreteRef,UInt8}` → ConcreteRef) so the phi local is ref-typed, but the value compiled to
  a numeric constant (UInt8 literal like ExternRef=0x6f=111 → `i32.const 111`). `i32.const 111;
  local.set <ref local>` fails validation. Rewrites `0x41/0x42 <sLEB> 0x21 <uLEB ref-idx>` →
  `0xD0 <type> 0x21 <uLEB>` (ref.null). Secondary sub-rule: struct.new/array.new_fixed followed by a
  numeric opcode 0x80-0xC4 → DROP+UNREACHABLE for dead-code-after-unreachable boxing paths.
- **Source emitters:** `compile_phi_value` (stackified.jl:629); `set_phi_locals_for_edge!` phi
  local.set emission (stackified.jl:~1073-1209).
- **Blast radius:** the migrated typed builder already prevents the byte pattern at emit time via two
  guards in `set_phi_locals_for_edge!` — (1) structured type-compat branches in `compile_phi_value`
  (stackified.jl:649-814) box numeric→ExternRef via `struct_new!`+`extern_convert_any!` or fall back
  to `emit_phi_type_default`; (2) the PURE-6025 inline "final safety net" (stackified.jl:1186-1208)
  detects `phi_is_ref && phi_val_is_numeric` and substitutes `emit_phi_type_default(phi_local_type)`
  (ref.null for all ref types, stackified.jl:596-624) BEFORE the `local_set!`. The post-emission
  rewriter is a third redundant copy over already-corrected bytes. No other emitter produces
  numeric-const→ref-local (only int128.jl i64 const+local.set chains, outside the phi path). Probe
  (incl. p_union/p_unionvec/p_anyret) → 0 changed / 0 invalid. The DROP+UNREACHABLE sub-rule
  (generate.jl:1459-1467) is a distinct dead-code-boxing micro-rule but also showed 0-change.
- **Guarding test:** NONE (no test references the pass / PURE-6025). Backfill a golden test pinning:
  (a) a fn whose phi/SSA edge is a numeric literal into a ConcreteRef/ExternRef phi local emits
  `ref.null <type>` from the typed builder (assert valid module + ref.null present, no
  i32.const→local.set ref) — anchor on p_union (Int64→Union{Int,Float}, a WORKING corpus case);
  (b) the struct.new-then-numeric-opcode dead-code case emits DROP+UNREACHABLE. NOTE p_unionvec/
  p_anyret fail validation EVEN WITH the pass active → Loop-6 gaps, not cases this pass guards.
- **Action:** confirm the `WT_NEUTRALIZE=all` run GREEN, then delete `fix_numeric_to_ref_local_stores`
  + its 4 call sites (generate.jl:167; compile.jl:3228/3379/3459) — but FIRST backfill the golden
  test, because the bug class is real and the only thing now preventing it is the untested emit-time
  guards in stackified.jl.

---

## Loop 2 — collapse the two flow generators

### L2.a `flow_generator_dual_lowering` — load-bearing · risk HIGH · **DO LAST**
- **Locations:** `flow.jl:5` `generate_structured` (dispatcher); `flow.jl:53`
  `generate_branched_loops`; `flow.jl:846` `generate_loop_code`; `flow.jl:1820`
  `is_simple_conditional`; `flow.jl:1845` `generate_if_then_else`; `flow.jl:2325`
  `compile_nested_if_else`; `stackified.jl:5` `generate_complex_flow`; `stackified.jl:208`
  `generate_stackified_flow`; `conditionals.jl:199` `generate_void_flow`; `conditionals.jl:1740`
  `generate_nested_conditionals`; `conditionals.jl:3186` `generate_block_code`; `generate.jl:153`
  `generate_body → generate_structured` (sole top-level entry); `compile.jl:3224/3375/3455`
  `generate_structured` call sites; `generate.jl:2114-3950` `generate_stackified_flow` direct call
  sites (try/catch + nested-loop drivers, ~30 calls).
- **Compensates for:** NOT a byte-rewrite / bug-compensation item — structural DUPLICATION. flow.jl
  and stackified.jl are PARALLEL (not layered) lowerings: `generate_loop_code` special-cases simple
  single-loop-no-phi bodies; `generate_if_then_else` special-cases 2-3-block conditionals; while
  `generate_stackified_flow` is the general CFG-driven algorithm (CFG → dominators → emit each block
  once → block/br forward, loop/br backedge) that can lower the same shapes. Evidence: boundscheck/
  dead-region carving copied in both (flow.jl 40 hits, stackified.jl 32);
  `get_phi_edge_wasm_type`/`wasm_types_compatible` exist as both top-level (flow.jl) and nested
  (stackified.jl) copies. Split is historical/incremental (specialized generators predate; the
  stackifier was added for loops+phi+multi-conditional shapes — WHY comments flow.jl:16-20,
  stackified.jl:24-38). dart2wasm uses ONE stackifier-style lowering.
- **Source emitters:** `generate_loop_code`, `generate_if_then_else`, `generate_branched_loops`,
  `generate_void_flow`, `generate_nested_conditionals`, `generate_complex_flow`,
  `generate_stackified_flow`.
- **Blast radius:** MAXIMAL — ALL control-flow emission. **CRITICAL: the `WT_NEUTRALIZE` probe is
  INAPPLICABLE here.** The probe toggles only the 7 post-emission `fix_*` rewriters; there is NO
  neutralize gate on any flow generator (they are pre-emission EMITTERS at generate.jl:153, BEFORE
  any fix_*). The "0 changed bytes on 56 fns" result says NOTHING about whether the two lowerings
  are redundant and cannot be cited as evidence of dead flow code. Removing/merging a generator is a
  real semantic change to emitted bytes, NOT a provably-dead deletion.
- **Guarding test:** NONE as an automated assertion. Byte-identity guard EXISTS as a MANUAL harness
  only: `test/fuzz/migration_corpus.jl` (`migration_digest`) + `test/fuzz/cleanup_probe_corpus.jl`
  (`probe_digest`, 56 fns incl. loops p_sizeloop/p_pushloop/a_sumloop, conditionals v_cond/p_selnum,
  nested-ternary f_nested/p_nestsel, try/catch f_excep/p_tryc) frozen against
  `dev/migration_baseline.txt` (20 SHAs) — NOT wired into runtests/CI. Behavioral coverage IS live
  (~446 loop/conditional constructs in runtests.jl + the differential fuzzer). Backfill: (1) wire
  `probe_digest`/`migration_digest` into a CI byte-identity assert against the frozen baseline BEFORE
  touching flow code; (2) pin the named WHY-shapes — float_to_string double-loop
  (`generate_branched_loops`), the gap-`1bcb0e7214c3` throw-in-one-arm + unreachable shape
  (stackified.jl:32-38), PURE-314 void-with-loop phi-init (stackified.jl:13-15).
- **Action:** DEFER to LAST (largest/riskiest; must not block momentum — do L1 first). Plan when
  reached: (a) FIRST add the CI byte-identity assertion driving probe_digest/migration_digest vs
  `dev/migration_baseline.txt`; (b) consolidation TARGET = `generate_stackified_flow` as the single
  CFG-driven lowering (matches dart2wasm), incrementally retiring the specialized paths by
  re-routing each `generate_structured` branch one shape at a time: start simplest —
  `generate_if_then_else` (flow.jl:1845 / is_simple_conditional:1820) → then
  `generate_loop_code`/`generate_branched_loops` (flow.jl:846/901), folding in `generate_void_flow`;
  (c) per shape: expect NON-byte-identical output (specialized paths emit tighter sequences), so gate
  on the BEHAVIORAL triple (suite + fuzzer + wasm-tools validate), using byte-identity only to
  confirm shapes the stackifier ALREADY produces identically; (d) FIRST low-risk sub-step: collapse
  the duplicated boundscheck/dead-region + `get_phi_edge_wasm_type`/`wasm_types_compatible` copies
  into single shared helpers. Honest risk: a multi-round refactor, not a delete — treat it as its own
  mini-migration with the Workflow round protocol (re-verify before commit / revert offending file).

---

## Loop 3 — kill the byte-inspection hacks + drop the dead validator

### L3.a `drop_validate_emitted_bytes` — provably-dead · risk LOW
- **Locations:** `generate.jl:14` (def `validate_emitted_bytes!`), `generate.jl:6` (docstring ref),
  `generate.jl:104-108` (`has_unknown` → filter out "stack underflow" false positives),
  `generate.jl:240-241` (sole consumer: `@debug` of `ctx.validator.errors`); `conditionals.jl:3193`
  (ONLY live call site, inside `generate_block_code`), `conditionals.jl:3194` (`emit_raw!` uses
  UNMODIFIED stmt_bytes); `context.jl:48-50` (`validator::WasmStackValidator` field — "Advisory only
  … doesn't prevent compilation"); `instr_builder.jl:54,66` (InstrBuilder's OWN separate `b.v`
  validator); `instr_builder.jl:115-122` (`_check!` — the LIVE model that THROWS StackImbalanceError
  when strict); `validator.jl:42-52,117` (WasmStackValidator struct; has_errors).
- **Compensates for:** NOTHING in the byte stream — a diagnostic, not a fix pass (legacy PURE-414
  instrument). Pre-builder era: WT emitted raw bytes through scattered hand-written emitters with no
  live stack model, so this scanner was a "minimal first pass" (docstring generate.jl:8-12) — a
  partial-opcode walk that pushes/pops on `ctx.validator`, skips multi-byte/control/call/GC ops as
  "unknown", and on any unknown op deletes all "stack underflow" errors as false positives
  (generate.jl:104-108), making it advisory-only by design (context.jl:49). generate.jl:236-239
  already declares wasm-tools validate / wasm-opt the source of truth.
- **Source emitters:** (none — it never modifies bytes; conditionals.jl:3194 emits the original
  stmt_bytes; it never throws; output = `ctx.validator.errors` consumed solely by the @debug at
  generate.jl:240-241).
- **Blast radius:** removal of the function + call site + @debug + the orphaned `ctx.validator` field
  touches ONLY generate.jl and conditionals.jl:3186-3198. `ctx.validator` is read NOWHERE else (grep:
  only generate.jl:15-16,90-94,107,240-241). Because the scanner never modifies bytes and never
  throws, deletion is byte-identical AND behavior-identical BY CONSTRUCTION — consistent with the
  probe's 0-changed result (and this validator is not even in the 7-pass NEUTRALIZE set). The
  migrated typed InstrBuilder carries its OWN live per-op WasmStackValidator (`b.v`) wired into every
  typed method (instr_builder.jl:173+) with a strict throw path (`_check!`), fully superseding this
  scanner with broader, correct, per-instruction coverage. `ctx.validator` and `b.v` are SEPARATE
  instances — removing ctx.validator cannot affect the live builder model.
- **Guarding test:** EXISTS for the live replacement (no backfill needed). No test calls
  `validate_emitted_bytes!` or asserts on `ctx.validator.errors` (grep of test/ finds only a
  node_modules JS match). The live `b.v` strict model IS pinned: runtests.jl:1389-1403
  (`num!` → StackImbalanceError; `b.v` has_errors/stack_height) and runtests.jl:4351-4453
  (WasmStackValidator push/pop/instruction! type-mismatch + underflow cases).
- **Action:** Loop-3 delete: remove `validate_emitted_bytes!` (generate.jl:14-109), its
  `_get_local_type` helper IF unused elsewhere (verify), the call at conditionals.jl:3193, the
  @debug block at generate.jl:240-242. Then delete the orphaned `ctx.validator` field (context.jl:48-50)
  + its initializers (context.jl:115, context.jl:2500, compile.jl:3173/3217/3368/3449/3528/3613);
  confirm `grep '.validator'` (excluding `b.v`) is empty afterward. KEEP `src/builder/validator.jl`
  + all `b.v` usage (the live, test-pinned model). Bundle with the L1/L3 generate.jl byte-inspection
  family.

### L3.b `marker_triage_pure_wbuild_cg` — needs-suite-confirm · risk LOW
- **Locations:** `calls.jl:148-markers` (densest; e.g. 800-803, 939-988, 2393, 3367 byte-peek
  sites); `values.jl:1004` (`field_val_bytes[1]==Opcode.REF_NULL`); `values.jl:1126`
  (`field_val_bytes[end]==Opcode.EXTERN_CONVERT_ANY`); `stackified.jl:76-111`
  (`has_ref_producing_gc_op`: LEB-skip + 0xFB GC-op byte scan); `context.jl:2124-2153`
  (`_get_local_wasm_type`: LEB-decode local.get index from bytes); `values.jl:140-168`
  (`return_type_compatible`; PURE-207 + WBUILD-4000 lattice special-cases); `generate.jl:155-235`
  (fix_* dispatch block, all markered); `generate.jl:191` (WBUILD-1011: fix_consecutive_local_sets
  disabled); `test/runtests.jl:10871-10898` (Phase 76 pins fix_i32_wrap_after_i32_ops byte-fixer).
- **Compensates for:** documentation debt, not an emission bug. The 939 PURE-/WBUILD-/CG- markers
  are inline provenance/justification annotations — 825/939 (88%) are pure-comment WHY lines; only
  114 are inline trailing tags, mostly on already-migrated typed-builder calls (struct_get!, ref_i31!,
  FieldType defs), state flags (last_stmt_was_stub=PURE-908), and the stub-clearing convention
  (empty!(bytes)=PURE-908). 141 distinct codes; WBUILD-NNNN doubles as feature/phase IDs linked to
  runtests phases (WBUILD-1021..1024, 2020-2023 = math/edge-case phases). The load-bearing subset it
  points at: (iii) recovering a sub-expression's wasm type by peeking leading/trailing opcode of
  recursively-compiled bytes (`field_val_bytes[1]==Opcode.REF_NULL`, `...[end]==EXTERN_CONVERT_ANY`,
  `val_bytes[1]==I32_CONST`) or by LEB-decoding (`has_ref_producing_gc_op`, `_get_local_wasm_type`) —
  compensating for the OLD raw-Vector{UInt8} emission having no type channel, a property the typed
  InstrBuilder now carries as the pushed WasmValType up front.
- **Source emitters:** `fix_array_len_wrap`, `fix_i32_wrap_after_i32_ops`, `fix_i64_local_in_i32_ops`,
  `fix_local_get_set_type_mismatch`, `fix_broken_select_instructions`,
  `fix_numeric_to_ref_local_stores`, `has_ref_producing_gc_op`, `_get_local_wasm_type`,
  `return_type_compatible`.
- **Blast radius:** removing the marker TAGS = zero behavioral effect (comments/labels — consistent
  with the probe's 0-changed result). The 88% comment-only majority can be un-tagged freely (cat ii).
  Load-bearing risk concentrates in the ~82 byte-inspection call sites + `has_ref_producing_gc_op`
  (23 call sites across calls/conditionals/statements/values/invoke.jl) + `_get_local_wasm_type`
  (3 sites): deleting THOSE is a Loop-3 refactor (changes control flow — they gate boxing/coercion
  decisions), not a marker edit. `return_type_compatible` touches every cross-type return/phi/select
  coercion (Loop-4, broad). The fix_* markers ride out with the provably-dead passes.
- **Guarding test:** PARTIAL. Phase 76 (runtests.jl:10871) directly pins
  `fix_i32_wrap_after_i32_ops` AND documents the canonical byte-scan unsoundness (LEB128 type-index
  167 = `0xA7 0x01` colliding with i32.wrap_i64's 0xA7, so the scanner corrupted a select_t/if ref
  operand). WBUILD-1021..1024/2020-2023 pinned by runtests math phases. The byte-inspection helpers
  (`has_ref_producing_gc_op`, `_get_local_wasm_type`) have NO direct unit test. Backfill: per-category
  un-tag is doc-only (no test); but each Loop-3 byte-peek site replaced by typed-IR inspection needs
  a regression pinning the boxing/coercion decision it gated (numeric→ref-field store, externref
  array element, Union-return coercion).
- **Action:** terrain-mapping, not a per-marker delete. Three tracks: (1) cat (ii) — the 825
  comment-only + benign-inline markers on migrated builder calls → bulk un-tag (drop the
  PURE-/WBUILD-/CG- token, keep the WHY prose) as a no-risk doc pass once Loops 1/3/4 land; preserve
  WBUILD-NNNN codes that index runtests phases. (2) cat (i) — markers ON the fix_* dispatch block
  (generate.jl:155-235) + return_type_compatible's PURE-207/WBUILD-4000 → ride out with Loop 1
  (dead passes) + Loop 4 (lattice). (3) cat (iii), the load-bearing work — ~82 recursive-result
  byte-peek sites + `has_ref_producing_gc_op` (23 callers) + `_get_local_wasm_type` → Loop 3: replace
  byte-scan type-recovery with the typed builder's pushed WasmValType; backfill the boxing/coercion
  regressions these gate, citing the Phase-76 opcode/operand-aliasing bug as the soundness
  motivation.

---

## Loop 4 — replace `return_type_compatible` with a principled lattice

### L4.a `return_type_compatible_lattice` — load-bearing · risk HIGH · **DO NOT DELETE**
- **Locations:** `values.jl:136` (def); `values.jl:88` (doc ref in `infer_value_wasm_type`
  narrow-int arm); call sites `flow.jl:145`, `flow.jl:240`, `flow.jl:1256`, `flow.jl:1539`,
  `flow.jl:1704`, `flow.jl:2035`, `conditionals.jl:59`, `stackified.jl:1348`, `stackified.jl:1604`;
  `stackified.jl:1583` (@warn diagnostic call, `_debug_stackified` only).
- **Compensates for:** NOT patch-debt — the type-decision that prevents the WasmGC validator
  rejecting a return whose stack value type ≠ declared result type. At each of 10 call sites a
  3-way branch: (1) numeric value + ref return → ref.null/numeric→externref box (PURE-315 arm,
  checked first); (2) `!return_type_compatible` → `unreachable!` (trap/reject); (3) else →
  compile_value + a fixed numeric-widening/extern-convert coercion ladder + `return!`. **Arms to
  preserve in any replacement:** EQUALITY value==return→true. EXTERNREF SINK (no PURE id): return
  ExternRef accepts {ConcreteRef,StructRef,ArrayRef,AnyRef,ExternRef}. ANYREF SINK (no PURE id):
  return AnyRef accepts {ConcreteRef,StructRef,ArrayRef}. PURE-207 (values.jl:148-152): value I32
  compatible with return I64 ("Union{Nothing,Int64}", needs i64_extend_i32_s). WBUILD-4000
  (values.jl:153-159): return ConcreteRef accepts {EqRef,StructRef,AnyRef,ConcreteRef} (needs
  ref.cast). STRUCTREF SUPER (values.jl:160-165, no PURE id): return StructRef accepts
  {EqRef,AnyRef,ConcreteRef}. Else → false (trap). **Coercion arms living at the CALL SITES** (must
  be subsumed by ONE coerce() routine): ExternRef←non-extern ⇒ extern.convert_any; I32→I64 ⇒
  i64_extend_i32_s; I64→F64 ⇒ f64_convert_i64_s; I32→F64 ⇒ f64_convert_i32_s; F32→F64 ⇒
  f64_promote_f32; I64→F32 ⇒ f32_convert_i64_s; I32→F32 ⇒ f32_convert_i32_s. PURE-315 pre-arm:
  numeric + ref return ⇒ synthesize ref.null/extern-boxed numeric. PURE-6024 (stackified.jl:1598):
  must key off `func_ret_wasm` (signature type) NOT `julia_to_wasm_type_concrete` (they disagree for
  Union{Int128,Int64,BigInt}: func_ret=I64, concrete=tagged-union ConcreteRef). PURE-6025/known-false-
  alarm (STRICT_MODE_INVENTORY D, stackified.jl ~1890): the predicate "incorrectly fails" when a phi
  local was overridden to i64 though the value is correct — a soundness-neutral false trap the
  lattice must resolve as a VALID coercion, not unreachable.
- **Source emitters:** `infer_value_wasm_type` (values.jl) produces value_type;
  `get_concrete_wasm_type` (types.jl:1749) produces func_ret_wasm/return_type; ReturnNode handlers
  in flow.jl/stackified.jl/conditionals.jl are the only consumers (emit the ladder or unreachable!).
- **Blast radius:** removing the predicate (returning true unconditionally) would let value/return
  mismatches reach the WasmGC validator → invalid modules at every ReturnNode where a phi/union value
  type ≠ declared result (exactly the union/boxing return paths). **The dynamic 0-byte probe DOES NOT
  cover this** — WT_NEUTRALIZE gates ONLY the 7 fix_* byte-rewriters in generate.jl (no
  WT_NEUTRALIZE reference exists outside generate.jl); this predicate is neither a fix_* pass nor in
  generate.jl, and runs unconditionally on the migrated path. Probe corpus p_unionvec
  (Union{Int,Float} phi return) and p_anyret (Union{Int,String} return) route through this predicate's
  `unreachable!` arm and STILL fail wasm validation with passes active — confirming the trap is
  reachable and is the only thing keeping those modules from being even-more-invalid. A
  semantic-coverage gap (Loop-6 loud-reject/overlay), not deletable patch-debt.
- **Guarding test:** NONE. No test calls `return_type_compatible` or asserts module validity for the
  union/Any-return cases. cleanup_probe_corpus.jl defines p_unionvec/p_anyret that EXERCISE it but
  they currently produce invalid modules (no green assertion). `test/fuzz/STRICT_MODE_INVENTORY.md`
  (Cat D, lines 59-67) + `test/fuzz/failures/4c8236022172.md` document the sites narratively only.
  Backfill: for each of the 11 arms above, a `*_diff.jl`/fuzz case asserting the module validates AND
  (where coercion applies) is differentially correct vs native; plus a negative test pinning that a
  genuinely-incompatible return loud-rejects rather than silently traps.
- **Action:** DO NOT delete (L4 type-lattice, not L1 patch-deletion). Replace the predicate + the
  duplicated 7-line numeric coercion ladder at all 10 sites with: (a) a WasmGC HeapType subtype
  lattice (eq > {struct(>ConcreteRef/StructRef), array(>ArrayRef)}; any > eq; extern as a parallel
  sink; numeric scalars as their own incomparable nodes with an explicit widening table
  I32→I64/F32/F64, I64→F32/F64, F32→F64) and (b) ONE `coerce!(b, value_type, expected_type)` routine
  that emits ref.cast / extern.convert_any / i64_extend / f*_convert / f64_promote, returns a
  Coercible|NeedsTrap|Incompatible verdict, and folds in PURE-207, WBUILD-4000, the
  externref/anyref/structref sinks, PURE-6024 (always key off func_ret_wasm), PURE-315
  (numeric→ref synthesis), and resolves the stackified.jl:1890 i64-phi false-alarm as Coercible.
  Drive the Incompatible verdict through the Loop-6 `emit_unsupported_stub!`/loud-reject path (so
  p_unionvec/p_anyret become explicit out-of-subset rejects instead of silent invalid modules).
  Backfill the per-arm validating diff tests FIRST so the collapse is byte/behavior-pinned.

---

## Loop 5 — make strict the DEFAULT

No standalone census item. Driven by the L1/L4 outcomes: once the `fix_*` passes are gone and the
type lattice lands, arm `WT_BUILDER_STRICT` by default so the typed builder's `_check!`
(instr_builder.jl:115-122) becomes the hard gate (can't emit invalid; throws at the bug site), with
wasm-tools demoted to belt-and-suspenders. Prerequisite signal already observed: in several L1
entries (fix_array_len_wrap L1.f, fix_i32_wrap L1.b) the typed validator currently only COLLECTS the
mismatch (validator.jl:84-86) and does not throw with strict OFF — flipping strict on turns
type-directedness into an enforced invariant.

---

## Loop 6 — user-facing loud-reject diagnostics

No standalone census item; receives the routed semantic-coverage gaps. Out-of-subset Julia →
precise "what/where/why/how-to-rewrite" errors on the builder's `set_context!` source tracking +
the type model. Inbound from L4: the `return_type_compatible` Incompatible verdict (p_unionvec,
p_anyret) must surface here as explicit out-of-subset rejects. See *Side findings*.

---

## Recommended Loop-1 deletion order

Ordered by `still_needed` + `removal_risk` + guarding-test status (delete the safest, most-redundant
first to build momentum):

1. **`fix_consecutive_local_sets`** — FIRST. provably-dead, risk LOW, already removed from the prod
   path (WBUILD-1011/1012); the 3 remaining sites are dead self-host demos. Lowest blast radius of
   all. Backfill = one multi-target-phi diff test.
2. **`fix_i64_local_in_i32_ops`** — provably-dead, risk LOW; front-line wrap at calls.jl:4711
   strictly subsumes it. Backfill = validate+numeric diff on p_i64mix/p_widemul/p_idxi32.
3. **`fix_broken_select_instructions`** — provably-dead, risk LOW; typed `select_t!` / typed if-block
   replaces it. Backfill = struct/ref-ternary + high-local-index gcd diff.
4. **`fix_local_get_set_type_mismatch` + `fix_array_len_wrap` TOGETHER** — the COUPLED pair.
   `fix_array_len_wrap`'s only documented introducer is `fix_local_get_set_type_mismatch`, so they
   must retire in the same loop step (delete-order risk if split). `..._type_mismatch` is
   provably-dead (risk LOW); `..._array_len_wrap` is needs-suite-confirm (risk MEDIUM). Backfill =
   the i32-edge-into-i64-phi diff (for the former) + the byte-level strip+false-positive unit (for
   the latter). Do this step only after the `WT_NEUTRALIZE=all` suite run is GREEN.
5. **`fix_numeric_to_ref_local_stores`** — provably-dead but risk MEDIUM (real bug class, untested
   emit-time guards in stackified.jl). Backfill = ref.null-emit golden + DROP+UNREACHABLE case FIRST.
6. **`fix_i32_wrap_after_i32_ops`** — needs-suite-confirm, risk LOW; its existing Phase 76 unit tests
   the rewriter (deleted with it), so backfill an END-TO-END raw-byte assertion before deleting.
   Consider arming `WT_BUILDER_STRICT` in CI at this step (turns the collected I64-vs-I32 mismatch
   into a hard throw) — natural lead-in to Loop 5.

Then `drop_validate_emitted_bytes` (L3.a) can land alongside/after L1 — it is byte- and
behavior-identical by construction and shares the generate.jl byte-inspection family.

---

## Side findings

- **`p_unionvec` (Union{Int,Float} phi return) and `p_anyret` (Union{Int,String} return) fail wasm
  validation EVEN WITH all passes active.** No `fix_*` rescues them; they route through
  `return_type_compatible`'s `unreachable!` arm (the trap is reachable and is the only thing keeping
  the modules from being even-more-invalid). These are SEMANTIC-COVERAGE gaps, NOT structural
  patch-debt — **route to Loop 6** (loud-reject / overlay), wired off the L4 lattice's `Incompatible`
  verdict so they become explicit out-of-subset rejects instead of silent invalid modules.
- **`fix_i32_wrap_after_i32_ops` deadness is observation-only with strict OFF.** Prod runs
  `WT_BUILDER_STRICT` OFF, so the typed validator only COLLECTS the I64-vs-I32 mismatch
  (validator.jl:84-86) and does NOT throw — the builder is not a hard gate. Deadness rests on
  emitters being type-directed (confirmed static) + the pending behavioral suite. Arming strict in CI
  (Loop 5 lead-in) converts this from a behavioral observation to an enforced invariant.
- **Cross-pass coupling: `fix_array_len_wrap` ⟷ `fix_local_get_set_type_mismatch`.** The wrap-after-
  array.len pattern is a FIX-PASS-INDUCED artifact (introduced only by the sibling type-mismatch
  pass), not a primary-emitter artifact. Deleting one without the other can regress validation —
  recorded in the deletion order as a mandatory pair.
- **`flow_generator_dual_lowering` byte-identity harness is NOT CI-wired.** `migration_corpus.jl`
  (`migration_digest`) + `cleanup_probe_corpus.jl` (`probe_digest`) are frozen against
  `dev/migration_baseline.txt` but not asserted in runtests/CI — Loop 2's first action must wire them
  in before any flow refactor.
- **`return_type_compatible` PURE-6024 / func_ret_wasm disagreement.** For
  Union{Int128,Int64,BigInt}, `func_ret_wasm`=I64 but `julia_to_wasm_type_concrete`=tagged-union
  ConcreteRef; the L4 lattice must always key off the function signature type, else it mis-traps a
  valid Int64 return.
- **`return_type_compatible` documented false trap (stackified.jl:~1890, STRICT_MODE_INVENTORY Cat D).**
  The predicate "incorrectly fails" when a phi local was overridden to i64 though the value is
  correct — a soundness-neutral false trap. The L4 lattice must resolve this as a valid coercion, not
  `unreachable!`.

---

## Backfill-test checklist (every pass whose `guarding_test` is NONE)

For each, add the exact regression BEFORE deleting; run with the triple oracle (and, where noted,
`WT_NEUTRALIZE` unset so the migrated emit-time replacement is the code exercised).

- [ ] **`fix_consecutive_local_sets`** — a multi-target-phi differential-correctness test: one SSA
  value flows to ≥2 phi locals across a merge (swap / branch-merge that historically emitted
  consecutive `local.set`); assert compile + wasm-tools validate + run-equals-native. Pins
  `emit_phi_local_set!` (flow.jl:472).
- [ ] **`fix_i64_local_in_i32_ops`** — validate+numeric-equality diff on the probe shapes
  `f(a::Int64,b::Int32)=a+Int64(b)`, `f(a::Int32)=Int64(a)*2`,
  `f(v::Vector{Int64},i::Int32)=v[Int64(i)]`; assert validate passes AND result==native. Pins the
  front-line `get_phi_edge_wasm_type` wrap (calls.jl:4711-4722).
- [ ] **`fix_local_get_set_type_mismatch`** — a `compare_julia_wasm` fn where a loop/branch phi local
  is inferred I64 but one edge yields Int32, e.g.
  `function(n::Int64,k::Int32); a=Int64(0); for i in 1:n; a = i==1 ? Int64(k) : a+i; end; a; end`,
  plus an explicit i32-edge-into-i64-phi loop; assert Node result==native AND validate passes, run
  with `WT_NEUTRALIZE` unset. Pins the structural widening `set_phi_locals_for_edge!`
  (stackified.jl:1165-1172).
- [ ] **`fix_array_len_wrap`** — (1) a byte-level unit (mirror runtests.jl:10872): feed
  `[array.len, i32.wrap_i64]`, assert the wrap is stripped; feed the false-positive
  (`local.get 2043` = `[0x20 0xFB 0x0F]` + a LIVE i32.wrap_i64 + a type-index operand `0xA7 0x01`),
  assert it is preserved (pins the E-003 fn#107 forward-parse fix). (2) e2e length() is already
  pinned (catalogue.jl:159) — no new e2e needed, but it does not pin this byte rewrite. Delete in the
  same step as `fix_local_get_set_type_mismatch`.
- [ ] **`fix_numeric_to_ref_local_stores`** — a golden test pinning (a) a fn whose phi/SSA edge is a
  numeric literal into a ConcreteRef/ExternRef phi local emits `ref.null <type>` from the typed
  builder (assert valid module + ref.null present, no `i32.const→local.set ref`; anchor on p_union =
  Int64→Union{Int,Float}); (b) the struct.new-then-numeric-opcode dead-code case emits
  DROP+UNREACHABLE.
- [ ] **`fix_broken_select_instructions`** — a `compare_julia_wasm` differential test for (a) a
  struct/string-producing ternary `b ? Pt(1,2) : Pt(3,4)` and `x>0 ? "pos":"neg"`; (b) an ifelse
  over ref values; (c) a gcd-style loop whose phi condition local index ≥ 128 (re-pins the original
  `0xfb`-LEB-collision infinite-loop gap).
- [ ] **`fix_i32_wrap_after_i32_ops`** — an END-TO-END regression: compile p_i32chain / p_i64mix /
  p_idxi32 / p_bitsi32 and assert the RAW emitted bytes contain no `<0x45-0x78|0xD1> 0xA7` sequence
  AND wasm-tools validate passes (the typed builder emits correct wrap placement up front). NOTE the
  existing Phase 76 unit tests the rewriter being deleted — it does NOT cover this.

(Loop-3/4 backfills are tracked in their sections: per-arm validating diffs for
`return_type_compatible_lattice`; per-site boxing/coercion regressions for the byte-peek sites in
`marker_triage_pure_wbuild_cg`. `drop_validate_emitted_bytes` needs NO backfill — the live `b.v`
model is already pinned by runtests.jl:1389-1403 + :4351-4453.)
