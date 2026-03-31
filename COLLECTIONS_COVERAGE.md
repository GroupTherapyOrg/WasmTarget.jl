# Collections Coverage — WasmTarget.jl

Updated: 2026-03-31 (M10-M11 completion)

## Summary

- **Phase 61**: 84 tests using @inline reimplementations (supplementary)
- **Phase 62**: 10 bridge round-trip tests
- **Phase 63**: 22 sort + 8 filter + 8 map + 6 sum + 2 reduce + 2 prod + 3 min + 3 max + 5 reverse + 3 any + 3 all + 3 count = **68 tests** using **REAL Base functions**
- **11/12** Base collection functions work with real implementations
- **Bridge**: dart2wasm-style Vector marshalling (create/get/set/len)

## Real Base Function Status

| Function | Status | Phase 63 Tests | Notes |
|----------|--------|---------------|-------|
| `sort(v)` Int64 | REAL_BASE | 21 | Any size incl. n=200, shuffled, duplicates, edge cases |
| `sort(v)` Float64 | BROKEN | 1 (@test_broken) | ReinterpretArray stubs in radix sort path |
| `filter(pred, v)` | REAL_BASE | 8 | Any size, Int64 |
| `map(f, v)` | REAL_BASE | 8 | Any size, Int64+Float64 |
| `sum(v)` | REAL_BASE | 6 | 100+ elements (mapreduce_impl fixed) |
| `reduce(+, v)` | REAL_BASE | 2 | Any size |
| `prod(v)` | REAL_BASE | 2 | Any size |
| `minimum(v)` | REAL_BASE | 3 | Int64+Float64 |
| `maximum(v)` | REAL_BASE | 3 | Int64+Float64 |
| `reverse(v)` | REAL_BASE | 5 | Int64+Float64 |
| `any(pred, v)` | REAL_BASE | 3 | Any size |
| `all(pred, v)` | REAL_BASE | 3 | Any size |
| `count(pred, v)` | REAL_BASE | 3 | Any size |
| `unique(v)` | DEFERRED | 0 | Needs Set/Dict support (infinite recursion + major feature) |

## JS↔WasmGC Bridge

WasmGC structs (Vector, etc.) are opaque to JavaScript. The bridge pattern (same as dart2wasm) exports factory/accessor functions alongside user code:

```julia
_bv_i64_new(n::Int64)::Vector{Int64} = Vector{Int64}(undef, n)
_bv_i64_set!(v::Vector{Int64}, i::Int64, val::Int64)::Int64 = (v[i] = val; Int64(0))
_bv_i64_get(v::Vector{Int64}, i::Int64)::Int64 = v[i]
_bv_i64_len(v::Vector{Int64})::Int64 = Int64(length(v))
```

## Known Issues

1. **sort(Float64)**: Compiles but radix sort path uses ReinterpretArray and `#send_to_end!#12` which are stubbed. Int64 sort works perfectly.

2. **unique**: Infinite recursion in auto-discovery (resolves unique to itself). Even if fixed, requires Set{T}/Dict{T} support. Deferred.

3. **Phase 61 reimplementations**: Still present as supplementary tests. They test WasmTarget's ability to compile Julia constructs (loops, push!, array access) but are not primary tests for any function that has a Phase 63 equivalent.
