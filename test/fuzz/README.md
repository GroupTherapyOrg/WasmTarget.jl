# Differential fuzzer

Generates **well-typed** random compositions of Base functions and checks each
against native Julia. Native is both the **oracle** (the right answer) and the
**validity filter** (if it doesn't infer/run, the program is discarded before
wasm). Findings auto-shrink to a minimal reproducer, persist to a corpus that
replays first on every run, and become tracked, auto-closing gap files.

## Layout

| file | role |
|------|------|
| `harness.jl`    | compile once, run all sample inputs in ONE Node process |
| `bridge.jl`, `bridge_args.jl` | bit-exact value transport across the Node bridge |
| `catalogue.jl`, `generators.jl`, `statements.jl`, `structpool.jl` | type-directed program generation |
| `property.jl`, `oracle_policy.jl` | differential oracle + classification (`wrong_value` = soundness alarm); the frozen float tolerances |
| `ledger.jl`     | gap tracker — each failure → `failures/<id>.md`, auto-closes when fixed |
| `run.jl`        | entrypoint: `@check` loop + `DirectoryDB` corpus + ledger |
| `*_diff.jl`     | per-library differential sweeps, run by `test/fuzz_suite.jl` |
| `corpus/`       | Supposition `DirectoryDB` — committed regression ratchet |
| `failures/`     | one Markdown gap per distinct unfixed failure (`status: open` or `out_of_subset`) |

## The loop

```bash
julia --project=test/fuzz test/fuzz/run.jl            # discover → shrink → persist → document
julia --project=test/fuzz test/fuzz/run.jl sweep      # parallel discovery (time-boxed)
julia --project=test/fuzz test/fuzz/run.jl verify     # re-run open gaps; auto-close the fixed ones
julia --project=test/fuzz test/fuzz/run.jl rank       # open gaps grouped by root-cause family
julia --project=test/fuzz test/fuzz/run.jl coverage   # write the catalogue matrix, COVERAGE.md
julia --project=test/fuzz test/fuzz/stdlib_coverage.jl  # write STDLIB_COVERAGE.md
```

A gap's reproducer **throws while the bug is present and runs cleanly once fixed**,
so `verify` flips fixed gaps to `status: fixed` with no manual bookkeeping; a fixed
gap is then deleted in the commit that fixed it (Git keeps its history). A reproducer
that now fails with a `WasmCompileError` is `out_of_subset`: a loud, sound rejection.
`failures/INDEX.md`, `COVERAGE.md` and `STDLIB_COVERAGE.md` are regenerated reports
and are not committed. The `DirectoryDB` corpus replays every known counterexample
first, so a regression cannot silently return. CI runs a bounded pass via
`test/fuzz_suite.jl`, which treats the canonical bodies of `open` gaps as known.

`test_bridge.jl`, `test_bridge_args.jl` and `test_statements.jl` check the apparatus
itself (bridge round-trips, generator health), and `stdlib_coverage.jl check` checks that
README.md states the per-stdlib percentages it measures; `test/fuzz_suite.jl` runs all four
in the fuzz lane, and each runs standalone with `julia --project=test/fuzz <file>`.
