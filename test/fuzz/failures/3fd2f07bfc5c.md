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
**ROOT-CAUSED + FIXED 2026-06-22 (wt-soundness-loop-4).** Lead gap of the `cor`
cluster (`3fd2f07bfc5c 5d7d44dd7cb2 96ce40f373de eadbce55d36d`, all `compile_error`),
plus the bonus Dict-`get` gap `ef3c54645d9f`.

**Triage:** general `cor` — `cor(a,b)`, `cor([x,x,x],…)`, AND 1-arg `cor(a)` all
failed identically; `cov`/`var`/`mean` compiled clean. So not value-/literal-specific.

**Mechanism:** `Statistics.cor` computes its result type via
`one(float(nonmissingtype(eltype)))`. The native optimizer concrete-evaluates this
whole chain to the constant `1.0` (1-arg) / a clean `corm` path (2-arg). WT's
`WasmInterpreter`, however, *disabled concrete-eval unconditionally* (the
GPUCompiler `:none` pattern), so inference left `nonmissingtype`/`float`/`one`
applied to **Type VALUES** as runtime `dynamic` dispatch:
```
%15 = φ(Base.Bottom, …, Float64)::Any     # a Type computed at runtime via typesplit
%17 = dynamic Statistics.float(%15)::Any   # float(::Type)
%18 = dynamic Statistics.one(%17)::Any     # one(::Type)  → 1.0
```
WT cannot lower `dynamic` dispatch on Type values, so it stubbed those statements
to `unreachable`. Because the relooper passes basic-block values on the operand
stack, the stubbed (missing) producer left a successor BB's consumer (`ref.is_null`
/ `i32.eqz`) with an empty stack → `WasmValidationError: expected a type but
nothing on stack`. (Same empty-stack family as the deferred `1f6e77980994`.)

**Fix (`src/codegen/interpreter.jl`):** make `concrete_eval_eligible` overlay-aware
instead of blanket `:none`. GPUCompiler needs `:none` because GPU hardware diverges
from the host; WasmGC is IEEE-754 like the host and every WT overlay is verified to
MATCH native, so the only thing we must never fold is a call resolving to a WT
overlay — and plain `@overlay` (not `@consistent_overlay`) already taints such
calls' effects with inconsistency, so the DEFAULT effect-based eligibility refuses
them transitively. We defer to that default, plus belt-and-suspenders force `:none`
when the directly-resolved method is itself a WT overlay
(`external_mt === WASM_METHOD_TABLE`). Pure overlay-free Type-level computations
(`nonmissingtype`/`float`/`one`) now fold to constants exactly as native inference
does → `cor` lowers to `return 1.0` / a clean `corm` path.

**Verified:** all 5 gaps auto-closed via `run.jl verify`; soundness sentinels
(`sin`/`sqrt`/`string`/`repeat(::Char)` with const args) still MATCH native via the
bridge (overlays respected, not bypassed); `cor(a,b)`/`cor(a)` return `1.0` bit-exact
vs native. Full `Pkg.test()` green.
