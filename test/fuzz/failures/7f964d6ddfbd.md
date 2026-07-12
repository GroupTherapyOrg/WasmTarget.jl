---
id: 7f964d6ddfbd
status: fixed
category: compile_error
kind: compile_error
construct: "compile_error: `abs(length(Dict(\"\" => \"\", \"\" => \"\")))` :: Int64"
location: "test/fuzz (generated)"
fn_name: repro
arg_types: "(Int64,)"
first_seen: run-12648430-d3
---

# Gap `7f964d6ddfbd` — compile_error: `abs(length(Dict("" => "", "" => "")))` :: Int64

**Category:** `compile_error` &nbsp;•&nbsp; **Kind:** `compile_error` &nbsp;•&nbsp; **Location:** `test/fuzz (generated)`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.
A follow-up loop fixes the compiler, then `verify_gaps!()` re-runs this to auto-close the gap.

```julia
using WasmTarget
include(joinpath("test", "fuzz", "structpool.jl")); using .FuzzStructPool
FuzzStructPool.build_pool!()
repro(x::Int64) = abs(length(Dict("" => "", "" => "")))
WasmTarget.compile(repro, (Int64,))   # raises while the gap is present
```

## Diagnostic
```
ArgumentError: branch target is not an open label
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
_(No analysis yet. Add root-cause notes below the `## Analysis` heading — they are PRESERVED across re-records.)_
