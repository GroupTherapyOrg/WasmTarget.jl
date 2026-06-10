# Stubbed Base Methods — coverage-gap inventory

Reference inventory (not auto-verifying gaps) of the Base helpers WasmTarget
currently lowers to `unreachable` (a **sound trap**: it aborts if executed, never
returns a wrong value). Harvested from the `strict=true` suite run — these are the
distinct `unsupported_method` stubs that fire across the 2409-assertion suite.

Most are **error-throwing helpers on dead branches** that Julia's typed IR keeps
but never executes for valid inputs, which is why the suite is green: the trap is
never reached. The ones marked **REACHABLE** trap at runtime for specific inputs —
those are real divergences (Julia throws a catchable error; wasm traps) and are
prime targets for the differential fuzzer (Phase 2), which will record each one it
hits as a `divergent_throw` / `runtime_trap` gap in this directory.

| Method | sites | reachability | trigger input | fuzzer target |
|--------|------:|--------------|---------------|:-------------:|
| `kwerr` | 86 | dead | invalid keyword args (valid code never hits) | — |
| `throw_complex_domainerror` | 44 | **REACHABLE** | `sqrt(-x)`, `log(-x)` on Float64/Float32 | ✓ |
| `__throw_gcd_overflow` | 26 | edge | `gcd(typemin(Int), …)` | ✓ |
| `mapreduce_empty_iter` | 26 | **REACHABLE** | `reduce`/`mapreduce`/`sum` over empty vector | ✓ |
| `reduce_empty` (several RFs) | ~11 | **REACHABLE** | empty `reduce`/`findmin`/`findmax` | ✓ |
| `throw_exp_domainerror` | 9 | edge | `x^y` domain edges | ✓ |
| `sincos_domain_error` | 6 | **REACHABLE** | `sincos(Inf)`, `sincos(NaN)` | ✓ |
| `paynehanek` | 6 | **REACHABLE** | `sin`/`cos`/`tan` of large‑magnitude float (`sin(1e300)`) | ✓ |
| `throwdm` (Broadcast) | 6 | dead* | mismatched broadcast shapes (*broadcasting itself is `@test_broken` on 1.13) | — |
| `_var_lt` | 2 | n/a | test helper (`test/helpers/subtype.jl`), not Base | — |

## How follow-up loops use this

1. The fuzzer (Phase 2) generates well-typed compositions including these triggers
   (negative `sqrt`, empty `reduce`, large-arg trig). When native Julia throws and
   the wasm module traps, it records a `divergent_throw` gap via `Ledger.record_gap!`.
2. Decide per gap whether the contract should be **match-the-throw** (emit a
   catchable wasm exception mirroring Julia's `DomainError`/`BoundsError`) or
   **document-as-known-divergence**. `paynehanek` and `reduce_empty` are the most
   likely to warrant real implementations.
3. `kwerr` / `throwdm` are genuinely dead for valid code — leave as sound traps.
