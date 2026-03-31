# Collections Coverage — WasmTarget.jl

Updated: 2026-03-30 (M6-M8 completion)

## Summary

- **1346 total tests** passing (full suite)
- **Phase 61**: 84 tests using @inline reimplementations (supplementary)
- **Phase 62**: 10 bridge round-trip tests
- **Phase 63**: 43 tests using **REAL Base functions** via JS↔WasmGC bridge
- **10/12** Base collection functions work with real implementations
- **Bridge**: dart2wasm-style Vector marshalling (create/get/set/len)

## Real Base Function Status

| Function | Status | Phase 63 Tests | WASM Size | Notes |
|----------|--------|---------------|-----------|-------|
| `map(f, v)` | REAL_BASE | 8 | 5,975 B | Any size, Int64+Float64 |
| `any(pred, v)` | REAL_BASE | 3 | 5,674 B | Any size |
| `all(pred, v)` | REAL_BASE | 3 | 5,674 B | Any size |
| `count(pred, v)` | REAL_BASE | 3 | 5,865 B | Any size |
| `sum(v)` | REAL_BASE | 6 | 6,740 B | 100+ elements (mapreduce_impl fixed) |
| `reduce(+, v)` | REAL_BASE | 2 | 6,729 B | Any size |
| `prod(v)` | REAL_BASE | 2 | 6,745 B | Any size |
| `minimum(v)` | REAL_BASE | 3 | 6,815 B | Int64+Float64 |
| `maximum(v)` | REAL_BASE | 3 | 6,815 B | Int64+Float64 |
| `reverse(v)` | REAL_BASE | 5 | 6,372 B | Int64+Float64 |
| `sort(v)` | BROKEN | 2 (@test_broken) | 16,217 B | Compiles but sort internals produce wrong results |
| `filter(pred, v)` | BROKEN | 1 (@test_broken) | 8,684 B | Hits unreachable (bounds check/resize) |
| `unique(v)` | NOT_TESTED | 0 | 5,300 B | Entire function stubbed |

## JS↔WasmGC Bridge

WasmGC structs (Vector, etc.) are opaque to JavaScript. The bridge pattern (same as dart2wasm) exports factory/accessor functions alongside user code:

```julia
# Bridge functions compiled alongside user function via compile_multi
_bv_i64_new(n::Int64)::Vector{Int64} = Vector{Int64}(undef, n)
_bv_i64_set!(v::Vector{Int64}, i::Int64, val::Int64)::Int64 = (v[i] = val; Int64(0))
_bv_i64_get(v::Vector{Int64}, i::Int64)::Int64 = v[i]
_bv_i64_len(v::Vector{Int64})::Int64 = Int64(length(v))
```

JS usage:
```javascript
const vec = exports._bv_i64_new(3n);
exports['_bv_i64_set!'](vec, 1n, 10n);  // 1-indexed
exports['_bv_i64_set!'](vec, 2n, 20n);
exports['_bv_i64_set!'](vec, 3n, 30n);
const result = exports.f_sum(vec);  // 60n
```

## Phase 61 (Supplementary — Reimplementations)

Phase 61 tests use hand-written @inline helpers (insertion sort, manual filter loops, etc.) that test WasmTarget's ability to compile Julia constructs (loops, push!, array access). These are supplementary to Phase 63's real Base function tests.

| Operation | Helpers | Tests |
|-----------|---------|-------|
| sort | `_t61_isort_i64!`, `_t61_isort_f64!` | 24 |
| filter | `_t61_filter_i64_positive/even`, `_t61_filter_f64_gt` | 13 |
| map | `_t61_map_i64_double/square`, `_t61_map_f64_square` | 13 |
| sum/reduce/prod | `_t61_sum_i64/f64`, `_t61_prod_i64/f64`, `_t61_reduce_*` | 16 |
| any/all/count | `_t61_any/all/count_i64_*` | 7 |
| reverse | `_t61_reverse_i64!/f64!` | 4 |
| unique | `_t61_unique_i64` | 2 |
| findmax/min | `_t61_findmax/min_i64/f64` | 5 |

## Known Issues

1. **sort**: Compiles to valid 16KB WASM. Sort internals (ScratchQuickSort, radix sort, partition!) produce wrong results when their stubs trap. Need deeper investigation of sort dispatch paths.

2. **filter**: Compiles to valid 8.7KB WASM with no stubs. Hits `unreachable` at runtime, likely from a bounds check in the growing-vector push! path. resize! and sizehint! compile but may have codegen issues.

3. **unique**: The entire function is stubbed during compilation (auto-discovery can't handle the complex dispatch). Returns unreachable immediately.

4. **mapreduce_impl**: Fixed in WBUILD-2014 by adding to AUTODISCOVER_BASE_METHODS. Previously caused sum/reduce/prod to trap for arrays >15 elements.
