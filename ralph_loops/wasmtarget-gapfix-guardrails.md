# Gap Fix Build Loop — Guardrails

## Rules

1. **NEVER reimplement a Base function.** Fix the compiler, wire dispatch, or add intrinsics. (See M5 incident in wasmtarget-build-guardrails.md.)
2. **NEVER return fake values from stubs.** If you can't implement it, emit UNREACHABLE with a clear comment.
3. **NEVER claim something works without a compare_julia_wasm test proving it.**
4. **ALWAYS read progress.md before starting** — it has the full history.
5. **ALWAYS run full test suite** — verify no regressions against baseline (1698 pass).
6. **TDD**: Write the test FIRST, verify it fails, then implement the fix.
7. **Minimal changes only.** Each fix has a LOC estimate in the gap analysis. If you're writing 10x more than estimated, STOP and reassess.

## Reference

- Gap analysis: `../ralph_loops/wasmtarget-gap-analysis.md` (in parent GroupTherapyOrg dir)
- Build PRD (prior work): `wasmtarget-build-prd.json`
- Build progress (prior work): `wasmtarget-build-progress.md`
