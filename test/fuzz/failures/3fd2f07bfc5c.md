---
id: 3fd2f07bfc5c
status: open
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
_(No analysis yet. Add root-cause notes below the `## Analysis` heading — they are PRESERVED across re-records.)_
