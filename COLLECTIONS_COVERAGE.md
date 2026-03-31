# Collections Coverage — WasmTarget.jl

Generated: 2026-03-30

## Summary

- **84 tests** in Phase 61 (WBUILD-1040 through WBUILD-1043)
- **1279 total tests** passing (full suite)
- All collection operations use pure-Julia `@inline` helpers compiled via `compare_julia_wasm`
- No compiler changes were needed for M5 — all patterns already supported

## Approach

Base.sort/filter/map IR is too complex for auto-discovery (ScratchQuickSort, Missing, NamedTuple dispatch). Instead, pure-Julia `@inline` helper functions are used. Julia inlines these at `code_typed` time, producing closure-free IR that compiles directly to WASM.

## Coverage

### sort (WBUILD-1040) — 24 tests

| Operation | Types | Status | Tests |
|-----------|-------|--------|-------|
| Insertion sort (ascending) | `Vector{Int64}` | COMPILES | 13 |
| Insertion sort (ascending) | `Vector{Float64}` | COMPILES | 11 |

Test cases: empty, single element, already sorted, reverse sorted, random (10 elements), duplicates, negative values, all-same, parameterized (5 each).

### filter (WBUILD-1041) — 9 tests

| Operation | Types | Status | Tests |
|-----------|-------|--------|-------|
| Filter positive | `Vector{Int64}` | COMPILES | 1 |
| Filter even | `Vector{Int64}` | COMPILES | 2 |
| Filter none match | `Vector{Int64}` | COMPILES | 1 |
| Filter all match | `Vector{Int64}` | COMPILES | 1 |
| Filter empty | `Vector{Int64}` | COMPILES | 1 |
| Filter > threshold | `Vector{Float64}` | COMPILES | 2 |
| Filter none match | `Vector{Float64}` | COMPILES | 1 |

### map (WBUILD-1041) — 9 tests

| Operation | Types | Status | Tests |
|-----------|-------|--------|-------|
| Map double | `Vector{Int64}` | COMPILES | 1 |
| Map square | `Vector{Int64}` | COMPILES | 1 |
| Map empty | `Vector{Int64}` | COMPILES | 1 |
| Map single | `Vector{Int64}` | COMPILES | 1 |
| Map preserves length | `Vector{Int64}` | COMPILES | 1 |
| Map negate | `Vector{Int64}` | COMPILES | 1 |
| Map square | `Vector{Float64}` | COMPILES | 1 |
| Map negate | `Vector{Float64}` | COMPILES | 1 |
| Chain: map then filter | `Vector{Int64}` | COMPILES | 1 |

### reduce/sum/prod (WBUILD-1042) — 13 tests

| Operation | Types | Status | Tests |
|-----------|-------|--------|-------|
| sum | `Vector{Int64}`, `Vector{Float64}` | COMPILES | 5 |
| reduce (+, max, min) | `Vector{Int64}` | COMPILES | 3 |
| prod | `Vector{Int64}`, `Vector{Float64}` | COMPILES | 5 |

Test cases: normal, empty, single, negatives, zero element.

### any/all/count (WBUILD-1042) — 10 tests

| Operation | Types | Status | Tests |
|-----------|-------|--------|-------|
| any (predicate) | `Vector{Int64}` | COMPILES | 3 |
| all (predicate) | `Vector{Int64}` | COMPILES | 3 |
| count (predicate) | `Vector{Int64}` | COMPILES | 4 |

Test cases: yes/no/empty for any/all; even/none/all/empty for count.

### reverse (WBUILD-1043) — 5 tests

| Operation | Types | Status | Tests |
|-----------|-------|--------|-------|
| Reverse in-place | `Vector{Int64}` | COMPILES | 3 |
| Reverse in-place | `Vector{Float64}` | COMPILES | 1 |
| Reverse preserves sum | `Vector{Int64}` | COMPILES | 1 |

Test cases: 5 elements, single, two elements, Float64, sum preservation.

### unique (WBUILD-1043) — 5 tests

| Operation | Types | Status | Tests |
|-----------|-------|--------|-------|
| Unique (O(n^2) scan) | `Vector{Int64}` | COMPILES | 5 |

Test cases: duplicates, all same, all different, preserves order, empty.

### findmax/findmin/argmax/argmin (WBUILD-1043) — 9 tests

| Operation | Types | Status | Tests |
|-----------|-------|--------|-------|
| findmax | `Vector{Int64}` | COMPILES | 3 |
| findmin | `Vector{Int64}` | COMPILES | 2 |
| findmax | `Vector{Float64}` | COMPILES | 1 |
| findmin | `Vector{Float64}` | COMPILES | 1 |
| argmax (index) | `Vector{Int64}` | COMPILES | 1 |
| argmin (index) | `Vector{Int64}` | COMPILES | 1 |

## Gaps and Future Work

| Operation | Status | Notes |
|-----------|--------|-------|
| `Base.sort` (native) | NOT SUPPORTED | IR too complex (ScratchQuickSort, Missing dispatch). Pure-Julia insertion sort used instead. |
| `Base.filter` (native) | NOT SUPPORTED | IR uses complex closure/GenericMemory patterns. Pure-Julia loop used instead. |
| `Base.map` (native) | NOT SUPPORTED | IR complexity. Pure-Julia loop used instead. |
| `push!` / `pop!` | COMPILES (internal) | Used internally by filter/unique helpers, works via GenericMemory. |
| `similar()` | COMPILES (internal) | Used internally by map helper. |
| `Dict` operations | NOT TESTED | SimpleDict/StringDict available (Phases 19-20) but not standard Dict. |
| `Set` operations | NOT TESTED | Could use SimpleDict as backing store. |
| `accumulate` / `cumsum` | NOT TESTED | Should work with pure-Julia loop approach. |
| `zip` / `enumerate` | NOT TESTED | Iterator protocol complexity. |
| `vcat` / `append!` | NOT TESTED | Should work with push! pattern. |

## Implementation Pattern

All collection operations follow this pattern:

```julia
# Define at module level (not inside @testset) to avoid closure capture
@inline function my_op(v::Vector{Int64})::Vector{Int64}
    result = Int64[]
    for i in 1:length(v)
        # ... operation logic ...
        push!(result, v[i])
    end
    return result
end

# Test wrapper calls the helper
@testset "op test" begin
    f()::Int64 = begin
        v = Int64[3, 1, 4, 1, 5]
        result = my_op(v)
        return Int64(length(result))
    end
    @test compare_julia_wasm(f).pass
end
```

Key design decisions:
1. `@inline` forces Julia to inline at `code_typed` time
2. Module-level placement avoids closure capture (functions inside `@testset` become closures)
3. Pure-Julia implementations avoid Base IR complexity
4. `compare_julia_wasm` is the oracle — runs in both Julia and WASM, compares results
