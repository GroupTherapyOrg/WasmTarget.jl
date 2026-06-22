---
id: 3fd2f07bfc5c
status: fixed
category: compile_error
kind: compile_error
construct: "compile_error: `cor([0.0, 0.0, 0.0], [0.0, x, x])` :: Float64"
location: "test/fuzz (generated)"
fn_name: repro
arg_types: "(Float64,)"
first_seen: sweep-expr-1
---

# Gap `3fd2f07bfc5c` — compile_error: `cor([0.0, 0.0, 0.0], [0.0, x, x])` :: Float64

**Category:** `compile_error` &nbsp;•&nbsp; **Kind:** `compile_error` &nbsp;•&nbsp; **Location:** `test/fuzz (generated)`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.
A follow-up loop fixes the compiler, then `verify_gaps!()` re-runs this to auto-close the gap.

```julia
using WasmTarget
include(joinpath("test", "fuzz", "structpool.jl")); using .FuzzStructPool
FuzzStructPool.build_pool!()
repro(x::Float64) = cor([0.0, 0.0, 0.0], [0.0, x, x])
WasmTarget.compile(repro, (Float64,))   # raises while the gap is present
```

## Diagnostic
```
WasmValidationError: wasm-tools rejected the emitted compiled module
error: func 3 failed to validate

Caused by:
    0: type mismatch: expected a type but nothing on stack (at offset 0x9b0)


emitted code at the failing offset:
(;@99d   ;)                                                                                                    local.set 25
(;@99f   ;)                                                                                                    local.get 25
(;@9a1   ;)                                                                                                    i32.eqz
(;@9a2   ;)                                                                                                    br_if 3 (;@53;)
(;@9a4   ;)                                                                                                    unreachable
(;@9a5   ;)                                                                                                    unreachable
(;@9a6   ;)                                                                                                    i32.eqz
(;@9a7   ;)                                                                                                    br_if 0 (;@56;)
(;@9a9   ;)                                                                                                    global.get 95
(;@9ab   ;)                                                                                                    local.set 2
(;@9ad   ;)                                                                                                    br 2 (;@54;)
(;@9af   ;)                                                                                                    end
(;@9b0   ;)                                                                                                    ref.is_null
(;@9b1   ;)                                                                                                    i32.eqz
(;@9b2   ;)                                                                                                    local.set 27
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
**ROOT-CAUSED + FIXED 2026-06-22 (wt-soundness-loop-4) via a `Statistics.cor`→`corm` overlay.** Lead
gap of the `cor` cluster (`5d7d44dd7cb2 96ce40f373de eadbce55d36d`, all `compile_error`). Triage:
general `cor` — `cor(a,b)`/`cor([x,x,x])`/1-arg `cor(a)` all fail; `cov`/`var`/`mean` are fine.

**Mechanism:** `Statistics.cor`'s result type is `one(float(nonmissingtype(eltype)))`. The native
optimizer concrete-evaluates that whole chain to a constant. WT's `WasmInterpreter` disables
concrete-eval (GPUCompiler `:none`), so those pure TYPE-LEVEL calls stay as runtime `dynamic`
dispatch on Type VALUES that WT can't lower → `unreachable` stub → relooper leaves a successor BB's
consumer (`ref.is_null`/`i32.eqz`) with an empty operand stack → `WasmValidationError: expected a
type but nothing on stack`. (Confirmed via `code_ircode` vs the trim CodeInfo:
`%17 = dynamic float(%15::Any)`, `%18 = dynamic one(%17)`.)

**Fix history.** A first attempt made `concrete_eval_eligible` fold all-Type-args calls
(`src/codegen/interpreter.jl`) — it closed all 4 cor gaps + passed full Pkg.test on Julia 1.12 but
REGRESSED Julia 1.13-rc1 (WT's overlaid string codegen errored; global concrete-eval perturbs WT's
version-specific string IR shapes). REVERTED. (An even broader earlier variant also regressed
`string(::Complex)`/`rand`/`quantile`/the fuzzer on 1.12.) **Lesson: changes to global inference
config are version-fragile and must clear the full CI matrix, not just 1.12-local.**

**The shipped fix (`ext/WasmTargetStatisticsExt.jl`):** a LOCAL overlay
`Statistics.cor(x::AbstractVector, y::AbstractVector) = Statistics.corm(x, mean(x), y, mean(y))`.
The leak lived entirely in cor's `x===y → one(float(nonmissingtype(eltype)))` fast path; `corm` is
the actual computation and is value-level throughout (it compiles cleanly, like `cov`/`var`/`mean`).
`corm(x,mean(x),y,mean(y))` is BIT-EXACT equal to native `cor(x,y)` for every input — general
(0.83…), anti-correlation (−1.0), equal-values (1.0), the `x===y` case (`clampcor`→exactly 1.0), and
the zero-variance gap input (NaN==NaN) — verified via the bridge. No global-inference change, so it's
1.13-safe (same kind as the existing median/quantile reroutes). 1-arg `cor(x)` is intentionally NOT
overlaid (no ledger gap; its value-independent `one(float(eltype))` genuinely needs the type-level
path — failing to compile there is loud, not a wrong value). NOTE: the Statistics extension must be
PRECOMPILED in the fuzz env for `run.jl verify` to see the overlay (a stale `test/fuzz` Manifest
hides it; `Pkg.resolve()` in that env precompiles it — the ext loads fine in the main/Pkg.test env).
