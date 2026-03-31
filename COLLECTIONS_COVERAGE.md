# Collections Coverage — WasmTarget.jl

Updated: 2026-03-31 (M12 completion — Float64 sort fixed)

## Summary

- **Phase 61**: 84 tests using @inline reimplementations (supplementary)
- **Phase 62**: 10 bridge round-trip tests
- **Phase 63**: 86 tests using **REAL Base functions** (0 @test_broken)
- **12/13** Base collection functions work with real implementations (unique deferred — needs Dict)
- **Bridge**: dart2wasm-style Vector marshalling (create/get/set/len)

## Real Base Function Status

| Function | Status | Phase 63 Tests | Notes |
|----------|--------|---------------|-------|
| `sort(v)` Int64 | REAL_BASE | 21 | Any size incl. n=200, shuffled, duplicates, edge cases |
| `sort(v)` Float64 | REAL_BASE | 17 | Any size, NaN→end, Inf/-Inf, -0.0/0.0 all correct |
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

1. **unique**: Requires Set{T}/Dict{T,Nothing} support. The dispatch chain: `unique(::Vector{Int64})` → AbstractArray method → `_unique_dims(A, :)` → `invoke(unique, Tuple{Any}, A)` → set.jl `unique(itr)` → creates `Set{T}()`. Dict is a major unimplemented feature (hash tables, probing, rehashing). Deferred until Dict support is added.

2. **Phase 61 reimplementations**: Still present as supplementary tests. They test WasmTarget's ability to compile Julia constructs (loops, push!, array access) but are not primary tests for any function that has a Phase 63 equivalent.

## Codegen Fixes for Float64 Sort (WBUILD-4000)

Two changes enabled Float64 sort:
- **values.jl**: `return_type_compatible` now allows EqRef/StructRef/AnyRef → ConcreteRef (needed for Union{Nothing,T} phi locals)
- **stackified.jl**: Emit `ref.cast_null` when return value wasm type differs from function return type (needed for struct ref downcasting)

## Harness Fixes for NaN/Inf (WBUILD-4002)

- **utils.jl**: Float64 bridge serializes NaN→`NaN`, Inf→`Infinity`, -Inf→`-Infinity` in JS
- **utils.jl**: JSON output uses string markers for NaN/Inf (JSON has no native representation)
- **utils.jl**: `_parse_f64` unmarshals string markers back to Float64
