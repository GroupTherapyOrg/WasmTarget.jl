---
id: cf0b9bbd2e46
status: fixed
category: compile_error
kind: compile_error
construct: "compile_error: `Int64(abs(median([0, x, x])))` :: Int64"
location: "test/fuzz (generated)"
fn_name: repro
arg_types: "(Int64,)"
first_seen: sweep-expr-4
---

# Gap `cf0b9bbd2e46` — compile_error: `Int64(abs(median([0, x, x])))` :: Int64

**Category:** `compile_error` &nbsp;•&nbsp; **Kind:** `compile_error` &nbsp;•&nbsp; **Location:** `test/fuzz (generated)`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.
A follow-up loop fixes the compiler, then `verify_gaps!()` re-runs this to auto-close the gap.

```julia
using WasmTarget
include(joinpath("test", "fuzz", "structpool.jl")); using .FuzzStructPool
FuzzStructPool.build_pool!()
repro(x::Int64) = Int64(abs(median([0, x, x])))
WasmTarget.compile(repro, (Int64,))   # raises while the gap is present
```

## Diagnostic
```
WasmValidationError: wasm-tools rejected the emitted compiled module
error: func 9 failed to validate

Caused by:
    0: type mismatch: expected anyref, found i32 (at offset 0xec76)
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis

**OPEN (P4-stdlib catalogue harvest, shared root).** All gaps in this
family reduce to `median(::Vector{Int64})` (and quantile-over-Int64)
composition contexts. Root cause: in `#_sort!#19_1` (the Int64-keyed
radix path), a `memoryrefnew(ref, i, bc)` RESULT is stored to an SSA
local. memoryrefnew compiles to a `[array_ref, i32_index]` stack PAIR
consumed inline by memoryrefget/set handlers — a single wasm local
cannot hold the pair, so the emission leaves `ref; index` on the stack
and the type-safety post-check appends a ref.cast that lands on the
i32 index (`expected anyref, found i32` at validation). Fix requires
either pair-locals (two locals per offset-ref SSA) or rewriting the
producer to fold the index into each consumer. Float64 median/quantile
are unaffected (different sort specialization). Pre-existing — exposed
by the catalogue's :stats slice, not introduced by it.

