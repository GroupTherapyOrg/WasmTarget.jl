# Gap Fix Build Loop — Progress

## Baseline
- **1698 pass, 0 fail, 0 error, 6 broken** (inherited from RALPH_COMPLETE, 2026-04-01)
- Gap analysis: 186 functions tested, 122 work (66%), 32 compile wrong, 25 stubbed

## Blocker Summary (from gap analysis)
| # | Blocker | Est LOC | Sprint | Priority |
|---|---------|---------|--------|----------|
| BF1 | Closure seen-set bug | 5 | 1 | CRITICAL |
| BF3 | contains/occursin | 50 | 1 | CRITICAL |
| BF4 | String interpolation | 10 | 1 | HIGH |
| BF5 | Dict loop insert | 30 | 1 | HIGH |
| BF2 | 10 trivial dispatch entries | 100 | 2 | HIGH |
| BF6 | SizeUnknown collect | 70 | 2 | MEDIUM |
| BF7 | SubString ref cast | 50 | 2 | MEDIUM |
| BF8 | 10 small dispatch entries | 150 | 3 | MEDIUM |
| BF9 | Dict pair iteration | 30 | 3 | MEDIUM |
| BF10 | JS bridges | 40 | 4 | LOW |
| BF11 | IOBuffer | 200+ | 4 | LOW |

---

## 2026-04-02: BF1 Closure Seen-Set Fix — COMPLETE

### BF-1000 (DISCOVER): Bug verified

**Root cause**: `_autodiscover_closure_deps!` (compile.jl:2166) uses a shared `seen` set for both:
1. **Collection phase** (lines 2170-2228): Scanning IR for invoke targets, adding each to `seen` for dedup
2. **Compilation phase** (lines 2236-2262): Iterating `all_deps` from `discover_dependencies()`, skipping entries in `seen`

Direct deps (filter, sort, mapreduce_impl) get added to `seen` during collection, then SKIPPED during compilation. Only transitive deps (resize! etc.) get compiled.

**Reproduction**: After `_autodiscover_closure_deps!` for `() -> filter(iseven, v::Vector{Int64})`:
- Before fix: func_registry contains `resize!` only (filter SKIPPED)
- After fix: func_registry contains `filter` AND `resize!`

### BF-1001 (BUILD): Fix applied — 7 LOC

Replaced the compilation loop's `seen` check with a fresh `compiled` set initialized from only func_registry (not the collection-phase additions):

```julia
compiled = Set{Tuple{Any, Tuple}}()
for (_n, infos) in func_registry.functions
    for info in infos
        push!(compiled, (info.func_ref, info.arg_types))
    end
end
```

File: `src/codegen/compile.jl`, lines 2235-2242 (inserted before compilation loop)

### BF-1002 (VERIFY): All tests pass

- **Before**: 1727 pass, 7 broken
- **After**: 1731 pass, 7 broken (+4 new BF1 tests, 0 regressions)

New tests (Phase 68 in runtests.jl):
- filter closure: `filter` and `resize!` in func_registry ✅
- sort closure: `#sort#24` in func_registry ✅
- sum closure: `mapreduce_impl` in func_registry ✅

### Key Learning
The `seen` set pattern (use one set for both dedup and skip) is a common bug pattern. The fix is to separate concerns: use `seen` for collection dedup, use a fresh `compiled` set (initialized from existing registry) for compilation skip.

---

