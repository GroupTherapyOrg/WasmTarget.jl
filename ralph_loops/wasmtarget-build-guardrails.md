# Compiler Gap Closure Guardrails

## Rules

1. **NEVER reimplement a Base function.** Fix the compiler or bridge. (See M5 incident: 28 reimplemented functions deleted in commit c20419d.)
2. **NEVER return fake values from stubs.** If you can't implement it, emit UNREACHABLE with a clear comment.
3. **NEVER claim something works without a compare_julia_wasm test proving it.**
4. **ALWAYS read progress.md before starting** — it has the full history.
5. **ALWAYS run full test suite** — verify no regressions against baseline (1527 pass).
6. **TDD**: Write the test FIRST, verify it fails, then implement the fix.

## M5 Incident Report (2026-03-31)

Previous iteration wrote 28 reimplemented functions pretending to be Base function tests. Examples: manual sorting loops instead of sort(), manual lowercase instead of lowercase(). All were deleted in commit c20419d. The correct approach is ALWAYS to fix the compiler so the real Base function compiles.

## Known Pre-Existing Failures (Not Regressions)

- Higher-order devirtualized (round inside closure): returns 0 — InexactError invoke issue
- Type conversion chains (Int64→Float64→Int32→Float32→Int64): returns 0 — same root cause
- Math functions (Phase 59/60): ~150 failures — stackifier issues, lower priority
- Subnormal inputs: 1 failure — lower priority
