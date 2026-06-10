---
id: eb1feee54ef1
status: fixed
category: compile_error
kind: compile_error
construct: "compile_error: `getindex(Dict(0 => 0.0, 0 => 0.0), 0)` :: Float64"
location: "test/fuzz (generated)"
fn_name: repro
arg_types: "(Float64,)"
first_seen: sweep-1-d4
---

# Gap `eb1feee54ef1` — compile_error: `getindex(Dict(0 => 0.0, 0 => 0.0), 0)` :: Float64

**Category:** `compile_error` &nbsp;•&nbsp; **Kind:** `compile_error` &nbsp;•&nbsp; **Location:** `test/fuzz (generated)`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.
A follow-up loop fixes the compiler, then `verify_gaps!()` re-runs this to auto-close the gap.

```julia
using WasmTarget
repro(x::Float64) = getindex(Dict(0 => 0.0, 0 => 0.0), 0)
WasmTarget.compile(repro, (Float64,))   # raises while the value-stub gap is present
```

## Diagnostic
```
WasmValidationError: wasm-tools rejected the emitted compiled module
error: func 1 failed to validate

Caused by:
    0: type mismatch: expected i64, found (ref $type) (at offset 0x31c)
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
_(No analysis yet. Add root-cause notes below the `## Analysis` heading — they are PRESERVED across re-records.)_
