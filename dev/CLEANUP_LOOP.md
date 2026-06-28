# WasmTarget Followup / Cleanup — the patch-debt-deletion loop (DISCOVERY-FIRST)

Branch: `wt-builder-cleanup` (off `wt-wasm-builder`, which is PR #70 — migration, do not merge yet).
Prereq DONE: the InstrBuilder migration is complete + validated (`Pkg.test()` GREEN, 2679 tests;
byte-identity-locked invariant in CI). See `dev/WASM_BUILDER_MIGRATION.md` + `dev/MIGRATION_PLAYBOOK.md`.

## Goal
Use the structured builder to meticulously remove the cheap hacky ad-hoc fixes — and PROVE each
removal safe with the **triple oracle**, backfilling a guarding test for every hack we delete.
End state: sound-by-construction emission + a principled type lattice = dart2wasm-level structural
production readiness.

## ⭐ ROOT-CAUSE MANDATE (Dale, 2026-06-28) — applies to EVERY loop, throughout
**When the triple oracle surfaces a real bug, ALWAYS fix the ROOT CAUSE at the emit site — never
defer, never work around, never paper over.** This is the loop's entire premise: a `fix_*` /
post-emission hack is deletable BECAUSE the migrated emitter is correct; the moment the oracle shows
an emitter is *wrong* (a `RED`), the deliverable becomes "make the emitter emit correct bytes by
construction" (the right algorithm / representation / type), then backfill a regression so it can
never silently return. A workaround that merely re-hides the symptom is the exact debt this loop
exists to delete. Fixing the root is in-scope by default — it is not a detour from the cleanup, it
IS the cleanup. (First instance: the multivar if/else phi-merge miscompile — routed to the
stackifier's correct per-edge phi-store instead of the value-block generators that dropped phis;
see the "CRITICAL FINDING" in `cleanup_ledger.md` + `test/fuzz/repro_multivar_phi_merge.jl`.)

## The triple oracle (why deletion is now safe)
Every cleanup step runs all three; green on all = the hack is gone for good:
1. **Strict model** (`WT_BUILDER_STRICT=1`) — structural/stack/type-balance breakage throws at the
   emit site with the Julia statement + stack snapshot (`builder_diagnose`).
2. **Full suite** (`Pkg.test()`, 2679 tests / 10 shards incl. Aqua) — behavioral regressions.
3. **Differential fuzzer** (Supposition, native Julia oracle) — silent value divergence.
NOTE: most cleanups are BEHAVIORAL (removing a fix_* pass changes output for the fns it rewrote),
so the oracle is suite+fuzzer, NOT the frozen byte-identity corpus. Use byte-identity only for
refactors that genuinely shouldn't change output (e.g. consolidating two flow generators).

## ⭐ The discovery instrument (the deep lever)
The 7 `fix_*` passes are POST-emission byte-rewriters that are STILL ACTIVE (that's why the
migration stayed byte-identical). The builder's strict model validates the emission BEFORE those
rewrites. Therefore:

> Running the suite with `WT_BUILDER_STRICT=1` makes the model throw a `StackImbalanceError` at
> EXACTLY the functions where the builder emits something a `fix_*` pass later corrects.

Each throw = one work item, pre-localized to a Julia statement + the stack shape. That maps the
entire patch→emission-bug correspondence automatically. (Today migrated emitters construct the
builder with `strict=_wt_builder_strict()`, so the env var already arms them.)

## PHASE 0 — DISCOVERY (do this FIRST, before deleting anything)
Produce `dev/cleanup_ledger.md` (the work-list). Two complementary sweeps:

A. **Strict-mode emission probe.** Run the suite/fuzz corpus with `WT_BUILDER_STRICT=1` and capture
   every `StackImbalanceError` (func_name + context + stack). Each = a function whose emission is
   unbalanced pre-fix_* → the emission bug a fix_* pass hides. Group by fix_* pass.
B. **Static patch census.** Inventory every debt item:
   - the 7 `fix_*` passes (`src/codegen/generate.jl`) + their 24 call sites — for each: what bug
     class it rewrites (mine the comment + body), which fns hit it, removal risk.
   - `validate_emitted_bytes!` (generate.jl + conditionals.jl, 3 calls) — is it load-bearing or a
     debug-gated no-op? 
   - the ~939 `PURE-/WBUILD-/CG-` ad-hoc markers — TRIAGE into: (i) reactive hacks that the strict
     model/type-lattice make redundant, (ii) legit handling to keep (just un-tag), (iii) byte-
     inspection hacks (`field_val_bytes[1] == Opcode.X`, LEB-decode of recursive results) now
     replaceable by IR/type inspection.
   - `return_type_compatible` (values.jl) — the special-case pile to replace with a real WasmGC
     HeapType lattice + one `coerce(value_type → expected_type)` routine.
   - the two flow generators (`flow.jl` + `stackified.jl`) — duplicate control-flow lowering.
   For each ledger item record: id · kind · location · compensates-for · blast-radius · target
   Loop (1-6) · removal-risk · guarding-test-exists? (else: backfill needed).
   PRIORITIZE: low-risk + high-redundancy first (build momentum + the byte-identity harness still
   guards the safe ones).

## THE CLEANUP LOOPS (work the ledger; same Workflow engine as the migration)
Per item: turn strict ON → remove/refactor the hack → run the triple → GREEN = delete it + backfill
a regression test pinning the case it handled → commit; RED = the oracle pinpoints what it
compensated for → fix it PROPERLY at the emit site (the typed builder should emit correct bytes
directly) + backfill test → commit.

- **Loop 1 — strict-on + delete the patch-debt.** Arm `WT_BUILDER_STRICT` in CI. Delete the 7
  `fix_*` passes + the patch sites + the dead-or-not validator, one at a time, triple-gated. The
  strict-mode probe (Phase 0.A) already told you which emission to fix first.
- **Loop 2 — collapse the two flow generators** into one (dart2wasm has one). Byte-identity-guardable.
- **Loop 3 — kill the byte-inspection hacks** (compile_value et al. scanning raw recursive bytes) →
  inspect the typed `Vector{WasmInstr}` / drive by types up front.
- **Loop 4 — replace `return_type_compatible`** with a principled WasmGC type lattice + a single
  coercion routine. The deepest production move (dozens of PURE-XXXX → one total function).
- **Loop 5 — make strict the DEFAULT** → sound-by-construction emission (can't emit invalid; throws
  at the bug site). wasm-tools demoted to belt-and-suspenders.
- **Loop 6 — user-facing loud-reject diagnostics.** Out-of-subset Julia → precise "what/where/why/
  how-to-rewrite" errors, riding on the builder's `set_context!` source tracking + the type model
  (distinct from internal WT-bug errors). Serves the blessed-rewrite strategy.

## Discipline: cleaning hacks == completing tests
Every hack you delete that the suite doesn't already cover → BACKFILL a regression test pinning the
case it handled, so the proper fix is locked and the case can never silently regress. A reactive
patch becomes principled code + a guarding test.

## ALSO bake in from the migration (reuse, don't reinvent)
- The Workflow engine + `MIGRATION_PLAYBOOK.md` patterns (discover → transform → verify → commit).
- The frozen byte-identity corpus harness (`test/fuzz/migration_corpus.jl` + `dev/migration_baseline.txt`)
  for any cleanup that SHOULD be byte-identical (Loop 2).
- The CI invariant guard (don't let raw emission creep back).
- The "independently re-verify before commit / revert offending file" round protocol.

## ⚙ OPERATIONAL PROTOCOL (learned 2026-06-28 — follow every round)
1. **NEVER edit `src/` while a `Pkg.test()` suite is running.** Shards precompile/load WT at start;
   editing mid-run contaminates the result (some shards load old, some new) and can race precompile
   (it cost a wasted ~stalled run). Serialize: edit → fast-check → suite → wait → next edit.
2. **Fast oracle BEFORE every expensive full suite** (~seconds vs ~15 min): `julia --project=. -e
   'using WasmTarget'` (compile-check — catches undefined refs/syntax from deletions) → compile the
   migration + `cleanup_probe_corpus.jl` corpora (no NEW `ERR`s; 2 pre-existing: p_unionvec/p_anyret)
   → run `test/cleanup_loop1_backfills.jl` + `test/fuzz/repro_multivar_phi_merge.jl` standalone
   (`include("test/utils.jl")` first). Only spend the full suite once these are green.
3. **Full suite via `Pkg.test()`** (NOT `julia test/runtests.jl` — that lacks test-only deps like
   Aqua and dies at line ~112). Background it; it's harness-tracked and re-invokes the loop on
   completion. A trailing `echo` masks the real rc → grep the log for `tests passed` /
   `Some tests did not pass`, don't trust the notification's exit code.
4. **Delete whole functions** with a boundary-aware text script (def line → first col-0 `end`, plus
   the preceding `"""docstring"""`/`#`-comment block); keep SHARED helpers. Verify no refs remain
   (`grep`), incl. tests that directly call the deleted fn (e.g. a Phase-NN unit test of a byte-fixer
   → delete it; its intent is covered e2e by the backfills).
5. **Oracle choice:** byte-identity (vs `dev/migration_baseline.txt`) only for refactors that SHOULD
   NOT change output; behavior-changing cleanups (deleting a live pass, the phi-merge fix) gate on
   the suite + diff fuzzer. After a behavior change, REGENERATE the baseline.
6. **ROOT-CAUSE MANDATE** (top of this file): a RED is a real emitter bug → fix at the source +
   backfill (flip the @test_broken repro to @test); never workaround.

## STATUS (2026-06-28, autonomous run)
- ✅ Phase 0 DISCOVERY done (instrument WT_NEUTRALIZE [now removed with the passes], dynamic probe,
  11-agent census → `dev/cleanup_ledger.md`).
- ✅ Soundness bug ROOT-FIXED: multivar if/else phi-merge → routed to stackifier (commit 70deff2).
- ✅ Loop 1 COMPLETE: the 7 dead `fix_*` passes + `_wt_neutralized` deleted, full suite GREEN (634f850).
- ✅ L3.a COMPLETE: `validate_emitted_bytes!` byte-scanner deleted (270bdf9) + the orphaned
  `ctx.validator` field/initializers removed (byte-identical). Checkpoint suite confirming.
- ✅ L4 down-payment COMPLETE (byte-identical): extracted the ReturnNode coercion block into
  `emit_return_coerced!(b, val, ctx)` (values.jl); replaced 8 of 9 sites (flow.jl ×6,
  conditionals.jl ×1, stackified.jl ×1), −187 lines. The 9th site (stackified.jl ~1563,
  generate_stackified_flow terminator) was LEFT inlined ON PURPOSE: its else-branch has extra
  WBUILD-4000 ref.cast branches + a val_bytes byte-inspection that conditionally skips
  extern_convert_any → NOT byte-identical → folds into L3/L4-proper. Byte-identical vs baseline;
  full suite confirming.

### ▶ REMAINING WORK — all DEEP/behavior-changing; do with the triple oracle, commit only GREEN
The "cheap hacky ad-hoc fixes" (the 7 fix_* byte-rewriters + the dead byte-scan validator) are
GONE. What remains is the deeper production-readiness refactoring — each is behavior-adjacent and
warrants care (the worst failure mode is a silent wrong-value regression on a path the suite
doesn't cover, so lean on the differential fuzzer + add targeted backfills for any newly-touched
path):
  - **L4 proper — principled WasmGC HeapType lattice + a single `coerce!`** replacing
    `return_type_compatible`'s special-case pile (values.jl:136) AND `emit_return_coerced!`'s
    else-branch ladder TOGETHER (you must only PERMIT a (value,return) pair if you also EMIT its
    coercion, else invalid wasm). A true lattice is MORE permissive than today's asymmetric rules
    (e.g. `return AnyRef` currently omits EqRef; ExternRef/AnyRef/StructRef sinks; PURE-207
    I32→I64; PURE-6024 always key off func_ret_wasm; the stackified.jl:~1890 i64-phi false-trap).
    NOT byte-identical → gate suite+fuzzer; resolve the `Incompatible` verdict into the L6
    loud-reject path so p_unionvec/p_anyret become explicit rejects, not silent invalid modules.
  - **L3 — kill byte-inspection hacks** (~82 `field_val_bytes[1]==Opcode.X` / LEB-decode sites +
    `has_ref_producing_gc_op` (23 callers) + `_get_local_wasm_type` + the inline dead-return
    rewriter + `strip_excess_after_function_end` in generate.jl + stackified.jl:1563's val_bytes
    scan) → drive decisions off the typed `Vector{WasmInstr}` / pushed WasmValType instead of
    scanning raw bytes. Behavior-preserving where possible (byte-identity-gate those); backfill the
    boxing/coercion case each gated. TIP: reuse the discovery-instrument trick — env-gate a hack,
    neutralize-probe across the suite; byte-identical-when-off ⇒ provably dead ⇒ delete.
  - **L2 — collapse the 3 flow generators into `generate_stackified_flow`** (flow.jl
    generate_if_then_else/generate_loop_code/generate_branched_loops + conditionals.jl
    generate_nested_conditionals → the one CFG-driven lowering). HIGH risk, DO LAST; NOT covered by
    the byte probe; FIRST wire `probe_digest`/`migration_digest` vs `dev/migration_baseline.txt`
    into CI, then re-route one shape at a time gated on suite+fuzzer. (The phi-merge fix already
    routes multi-phi merges here — a down-payment on this consolidation.)
  - **L5 — strict-by-default** (arm WT_BUILDER_STRICT once L3 lands so all emitters have exact
    stack models). **L6 — loud-reject diagnostics** for out-of-subset Julia (rides set_context! +
    the L4 lattice's Incompatible verdict).

## ▶▶ RESUME HERE
Branch `wt-builder-cleanup`. Phase 0 + phi-fix + Loop-1 deletions landed (see STATUS + git log).
Continue the loop sequence above, triple-gated per the OPERATIONAL PROTOCOL, committing green deltas,
root-fixing every RED. Memory: [[wt-builder-cleanup-loop]] · [[feedback-always-fix-root-cause]].
Migration record: [[wt-migration-loop]].
