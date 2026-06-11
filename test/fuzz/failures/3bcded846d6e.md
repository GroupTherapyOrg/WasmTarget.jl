---
id: 3bcded846d6e
status: fixed
category: compile_error
kind: compile_error
construct: "compile_error: `begin\n    acc_b = length(cumsum([Int32(0), Int32(0), Int32(0)]))\n    i_b = Int64(0)\n    while i_b < Int64(1)\n        acc_b = length(Dict(x => \"\", x => \"\")) + length(Dict(0 => x, x => x))\n        i_b = i_b + Int64(1)\n    end\n    acc_b\nend` :: Int64"
location: "test/fuzz (generated)"
fn_name: repro
arg_types: "(Int64,)"
first_seen: sweep-stmt-3
---

# Gap `3bcded846d6e` — compile_error: `begin
    acc_b = length(cumsum([Int32(0), Int32(0), Int32(0)]))
    i_b = Int64(0)
    while i_b < Int64(1)
        acc_b = length(Dict(x => "", x => "")) + length(Dict(0 => x, x => x))
        i_b = i_b + Int64(1)
    end
    acc_b
end` :: Int64

**Category:** `compile_error` &nbsp;•&nbsp; **Kind:** `compile_error` &nbsp;•&nbsp; **Location:** `test/fuzz (generated)`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.
A follow-up loop fixes the compiler, then `verify_gaps!()` re-runs this to auto-close the gap.

```julia
using WasmTarget
include(joinpath("test", "fuzz", "structpool.jl")); using .FuzzStructPool
FuzzStructPool.build_pool!()
repro(x::Int64) = begin
    acc_b = length(cumsum([Int32(0), Int32(0), Int32(0)]))
    i_b = Int64(0)
    while i_b < Int64(1)
        acc_b = length(Dict(x => "", x => "")) + length(Dict(0 => x, x => x))
        i_b = i_b + Int64(1)
    end
    acc_b
end
WasmTarget.compile(repro, (Int64,))   # raises while the gap is present
```

## Diagnostic
```
WasmValidationError: wasm-tools rejected the emitted compiled module
error: func 1 failed to validate

Caused by:
    0: type mismatch: expected i32, found i64 (at offset 0x1ea9)
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
_(No analysis yet. Add root-cause notes below the `## Analysis` heading — they are PRESERVED across re-records.)_
