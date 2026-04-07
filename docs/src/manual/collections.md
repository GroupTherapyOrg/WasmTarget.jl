# Collections

All 26 tested collection functions compile and produce correct results, verified with Vector{Int64} and Vector{Float64}.

## Supported Functions

| Function | Path | Notes |
|:---------|:-----|:------|
| `sort`, `sort!` | Overlay | Full kwarg support (`rev=true`) |
| `filter` | Overlay | Predicate closures |
| `map` | Native | Closures compile correctly |
| `reduce`, `foldl`, `foldr` | Native | |
| `sum`, `prod` | Native | |
| `minimum`, `maximum`, `extrema` | Native | |
| `any`, `all` | Native | Predicate closures |
| `count` | Overlay | |
| `unique` | Overlay | |
| `accumulate` | Native | |
| `findmax`, `findmin` | Native | |
| `argmax`, `argmin` | Overlay | |
| `mapreduce` | Native | |
| `foreach` | Overlay | Ref mutation pattern |
| `reverse` (Vector) | Native | |

## Example

```julia
using WasmTarget

f_sort(v::Vector{Int64}) = sort(v, rev=true)
f_filter(v::Vector{Int64}) = filter(iseven, v)
f_map(v::Vector{Int64}) = map(x -> x * 2, v)

bytes = compile_multi([
    (f_sort, (Vector{Int64},)),
    (f_filter, (Vector{Int64},)),
    (f_map, (Vector{Int64},)),
])
```

## Compositions

Functions compose correctly across native and overlay paths:

```julia
# 8-deep chain — all verified E2E
f(v::Vector{Int64})::Int64 = sum(unique(sort(filter(x -> x > 0, map(abs, accumulate(+, reverse(v)))))))
```

## Array Mutation

All 16 mutation functions work via overlays:

`push!`, `pop!`, `pushfirst!`, `popfirst!`, `insert!`, `deleteat!`, `append!`, `prepend!`, `splice!`, `resize!`, `empty!`, `fill!`, `copy`, `reverse`, `length`, `vec`
