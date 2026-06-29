# WasmTarget → dart2wasm production-parity loop

Branch `wt-dart2wasm-parity` (off main @ v0.4.0). Mission: **full 1:1 dart2wasm production-readiness
parity, no gaps.** Autonomous, aggressive, undoable (isolated branch). Driven by Dale 2026-06-29.

## Two oracles (every change)
- **dart2wasm = HOW** (`/Users/daleblack/Documents/sdk` pkg/{wasm_builder,dart2wasm}): the design oracle
  for the right shape (convertType, isSubtypeOf, classId+offset dispatch, typed Instruction hierarchy).
- **Julia compiler = VERIFICATION = CORRECTNESS**: the triple oracle — (1) `WT_BUILDER_STRICT` stack model,
  (2) full `Pkg.test()` (2679 tests/10 shards + Aqua), (3) differential fuzzer (native-vs-wasm).

> **⚠ BYTE-IDENTITY IS NOT THE PARITY GATE (Dale, 2026-06-29).** The `migration_corpus.jl` vs
> `dev/migration_baseline.txt` byte-identity check was a *migration-loop* safety net — valid ONLY for
> refactors that genuinely shouldn't change output. The old WT path is brittle/finnicky; REPLACING it with
> the dart2wasm design SHOULD change the bytes. **Don't preserve brittle code to keep bytes stable — DELETE
> it and verify the replacement by CORRECTNESS (differential native-vs-wasm + Pkg.test + adversarial sets).**
> Use byte-identity only as a convenience signal for a deliberately-output-preserving step, never as a reason
> to keep an off-ethos path alive.

## Discipline (from `dev/CLEANUP_LOOP.md` OPERATIONAL PROTOCOL — reuse it all)
Never edit src/ while a suite runs · `Pkg.test` not `runtests.jl` · run_in_background with NO inner `&` ·
fast-oracle before every full suite · delegate big mechanical refactors to gated sub-agents + central
verify · commit GREEN / revert RED+document / **root-fix at the emit site** · never pause/ask · always
end a turn with a running suite/agent (re-invokes me) or a ScheduleWakeup fallback.

## The gap ledger
Full per-dimension gaps + file:symbol citations: **`dev/PARITY_LEDGER.md`** (12 dimensions; F* = functional,
B* = bloat, P* = production). 8/12 "close", 4 significant-gap (boxing, coercion-funnel, closures, strings).
Root cause: WT lacks dart2wasm's ONE uniform value representation (classId-tagged box) + ONE coercion
funnel (convertType), both validated by ONE subtype relation WT has (`wasm_subtype`) but wired into ~nothing.

## LOOP ORDER (audit-recommended; the lattice is the keystone)
- **Loop 0 — free soundness banking (small, first):** P13 ref.cast subtype reject · P7 dedicated exception
  global/tag · F11 Int128 ctz/popcnt branch · F17 typed trunc_sat (retire a RawBytes splice). Each
  independent + small; gate on the differential fuzzer.
- **Loop A — harden the type lattice (keystone):** make `wasm_subtype` (src/codegen/values.jl)
  nullability-aware (P2) + walk `supertype_idx` for concrete types (F4); wire it into the live operand-stack
  validator replacing the permissive `wasm_types_assignable` (F6/P3); fix the NonNullAbstractRef MethodError
  (B6). Prerequisite for boxing + funnel + strict.
- **Loop B — union/dynamic boxing (#1 functional gap):** F1 numeric-only Union → classId-tagged box · P1 one
  global classId (retire the 3 disjoint tag schemes) · F9/F31 canonical box (no i31-vs-struct split) · P10
  uniform instantiateDummyValue. Moves boxing verdict significant-gap → close. Depends on Loop A.
- **Loop C — single convert_type! funnel + flow/phi dedup:** B1 collapse the 5+ coercion ladders into one
  convert_type! (delivers P9 ref.as_non_null, P21 needsConversion gate, B16 conditional unbox) · B2/B10
  collapse flow generators + kill phi byte-inspection · P11 symbolic Labels (kill manual br-depths) · B5
  single box/unbox funnel. Largest bloat-retirement; after B.
- **Loop D — strict-default + total loud-reject:** P5/P6 kill the ~20 silent-trap Cat-C stubs + named
  WasmCompileErrors (first-class-closure-value, mutated-capture) · P12/P15 strict builder ON by default ·
  P17 close the dependency/must-execute escape hatches · P14 local-init tracking · P19 dispatch-miss diag.
- **Loop E — closures + GC nominal hierarchy (largest delta, last):** F2/F3/B11 first-class closure value +
  capture-by-ref + capture-analysis · B3/P18 nominal struct subtype hierarchy + builder-derived field types ·
  F14/F16 packed numeric arrays + rec-groups.
- **Deferred / sub-loops:** string i16 rep (F7/F18/B8 — separate string-parity sub-loop) · EH driver rewrite
  (B7/P4/P8 — seeded by Loop 0's P7) · F30 linear memory (by-design out-of-subset) · F8/F22/F23 deeper
  lattice completeness · F12/F13 multi-arg + classId-table dispatch (fold into Loop E).

## THE ETHOS (re-read every step — do NOT get off track)
dart2wasm is the oracle; the real Julia compiler (differential native-vs-wasm + full Pkg.test) is the
verification. **PURE not cheap:** carry the real type, box only genuinely-dynamic — no type-by-init/hope,
no guessing, no loud-fail-as-substitute, no defer/settle. **Wire fixes THROUGHOUT + RETIRE the old code**
(the scattered anyref-boxing + ~120 byte-inspection sites = the `compile_value` type-channel debt B1 — the
pure typed-value approach lets it be DELETED, not patched around). Mechanistic, one site at a time, gated.
Goal: REAL dart2wasm parity AND same-or-way-more Julia coverage. Verify the VALUE, not just "compiles".
**The old approach is brittle — DON'T over-preserve it. Byte-identity is NOT the gate (see "Two oracles");
deleting off-ethos brittle code and re-verifying by correctness IS the ethos, not a deviation from it.**

## ▶▶ RESUME HERE
On `wt-dart2wasm-parity`. v0.4.0 ✅ LANDED (General #159556 merged + tag + GH release). Committed: Loops A
(lattice), B (numeric-Union box), C-B1 (convert_type! funnel), F31/F-i31, F11/F11b, sort/sortperm. ACTIVE =
the F3 pure sub-loop (`dev/F3_LOOP.md`: L0 pure join + L1 registry done → L2 wire the 4 sites). Then the #1
filtered-fold silent-wrong, then propagate the type-channel (B1) pure-typing compiler-wide (retiring boxing/
byte-inspection). Memory: [[wt-dart2wasm-parity-loop]]. Ledger: `dev/PARITY_LEDGER.md`. FINDINGS: `test/fuzz/FINDINGS.md`.
