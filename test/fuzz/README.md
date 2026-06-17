# Differential fuzzer — the self-fulfilling correctness loop

> **Driving an autonomous campaign?** Read **`LOOP.md`** first — it is the operational
> contract for the WasmTarget soundness `/loop` (tiered subset, anti-reward-hacking
> guardrails, per-iteration runbook, KPI). `loop_guard.sh` enforces the mechanical
> guardrails each iteration. This README describes the apparatus those drive.

Generates **well-typed** random compositions of Base functions and checks each
against native Julia. Native is both the **oracle** (the right answer) and the
**validity filter** (if it doesn't infer/run, the program is discarded before
wasm). Findings auto-shrink to a minimal reproducer, persist to a corpus that
replays first on every run, and become tracked, auto-closing gap files.

## Layout

| file | role |
|------|------|
| `harness.jl`    | compile once, run all sample inputs in ONE Node process |
| `generators.jl` | type-directed `ExprNode` trees (Int64/Float64 today; extend the op tables) |
| `property.jl`   | differential oracle + 5-way classification (`wrong_value` = soundness alarm) |
| `ledger.jl`     | gap tracker — each failure → `failures/<id>.md`, auto-closes when fixed |
| `run.jl`        | entrypoint: `@check` loop + `DirectoryDB` corpus + ledger |
| `corpus/`       | Supposition `DirectoryDB` — committed regression ratchet |
| `failures/`     | one Markdown gap per distinct failure + `INDEX.md` dashboard |

## The loop

```bash
julia --project=test/fuzz test/fuzz/run.jl          # discover → shrink → persist → document
julia --project=test/fuzz test/fuzz/run.jl verify   # re-run open gaps; auto-close the fixed ones
```

A gap's reproducer **throws while the bug is present and runs cleanly once fixed**,
so `verify` flips fixed gaps to `status: fixed` with no manual bookkeeping. The
`DirectoryDB` corpus replays every known counterexample first, so a regression
cannot silently return. CI runs a bounded pass via `test/fuzz_suite.jl`.

## Extending coverage (the ongoing crank)

Add ops to the tables in `generators.jl` (`INT_OPS`, `FLOAT_OPS`, and new ones for
`Vector{T}`, `String`, mixed-type conversions). The harness/oracle already handle
the loop; growing the op surface is how "all of core Julia, in arbitrary combos"
gets covered incrementally. See `failures/STUBBED_METHODS.md` for known reachable
trap branches worth targeting (`paynehanek`, empty `reduce`, …).
