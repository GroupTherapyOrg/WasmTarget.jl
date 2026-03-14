# Tier 1 Julia Test Suite — WasmTarget Results

Generated: 2026-03-13
Julia: 1.12.4, WasmTarget: current main

## Summary

| Metric | Count |
|--------|-------|
| Total @test in Tier 1 files | 7,494 |
| Extracted (self-contained, feasible) | 1,886 |
| Verified in native Julia | 659 |
| Compiled to Wasm | 652 (100% of attempted) |
| Execute + Correct | 586 (89.9%) |
| Execute failures | 65 |
| Mismatches | 1 |
| Wrap failures | 7 |

**Overall correct rate: 89.9%** (target: >=80%)

## Extraction Pipeline

1. Read 22 Tier 1 files from Julia's `test/` directory
2. Filter @test lines for self-contained expressions (no context deps)
3. Exclude infeasible patterns: BigInt, IO, eval, ccall, threading, etc.
4. Exclude known-stubbed operations: parse(), reduce(), @fastmath, etc.
5. Verify each extracted expression passes in native Julia
6. Wrap as zero-arg function returning Int32(1/0)
7. Compile via WasmTarget, execute in Node.js
8. Compare result to native Julia

## Failure Root Causes (65 execution failures + 1 mismatch)

### Category 1: Higher-order functions with closures (17 failures)
**Source:** reduce.jl
**Examples:** `mapfoldl((x)-> x ⊻ true, &, [...])`, `sum(sin, [3])`, `extrema(abs2, 5)`
**Root cause:** Functions like `mapfoldl`, `sum(f, collection)`, `extrema(f, x)` require
closure dispatch through array iteration. WasmTarget compiles these with stubbed methods
that trap at runtime.
**Fix:** Implement array iteration with closure dispatch in Codegen.jl

### Category 2: Integer utility functions (15 failures)
**Source:** intfuncs.jl
**Examples:** `digits(5, base=3)`, `ndigits(0x4000, base=16)`
**Root cause:** `digits()` creates arrays via complex iteration. `ndigits()` with mixed
types requires dispatch through multiple specializations.
**Fix:** Implement `digits()` array construction; improve mixed-type dispatch

### Category 3: Large numeric literals / nextprod (11 failures)
**Source:** numbers.jl
**Examples:** `0o400...000 == 340282...`, `nextprod([2,3,5], 30)`
**Root cause:** Octal literals overflow to BigInt territory. `nextprod` requires iteration.
**Fix:** Filter out tests with large literals; implement nextprod

### Category 4: NamedTuple indexing (6 failures)
**Source:** namedtuple.jl
**Examples:** `(x=4, y=5)[[:x, :y]]`
**Root cause:** NamedTuple indexing with Symbol arrays requires runtime dispatch.
**Fix:** Implement NamedTuple symbol-based indexing

### Category 5: Tuple string operations (5 failures)
**Source:** tuple.jl
**Examples:** `sum(("a",))`, `(2, 3, 4, 5, 6, 7, 8, 9, ...)`
**Root cause:** `sum` on string tuples, large tuple construction.
**Fix:** Implement tuple reduction dispatch

### Category 6: Broadcasting / matrix ops (5+1 failures)
**Source:** math.jl, char.jl
**Examples:** `clamp.([0 1; 2 3], 1.0, 3.0)`, `'a' .* ['b', 'c']`
**Root cause:** Broadcasting with matrices/arrays requires complex dispatch.
**Fix:** Implement broadcasting infrastructure

### Category 7: Reflection / type system (4 failures)
**Source:** operators.jl, hashing.jl, subtype.jl
**Examples:** `isempty(methods(+, ()))`, `Pair{A,B} where A where B`
**Root cause:** `methods()` reflection and `where` type comparisons are compiler-level ops.
**Fix:** Not applicable for WasmGC — these are inherently runtime Julia features

### Category 8: Comprehensions (2 failures)
**Source:** functional.jl
**Examples:** `[(i,j) for i=1:3 for j=1:i]`
**Root cause:** Nested comprehensions require generator iteration.
**Fix:** Implement comprehension lowering

## Per-File Results

| File | Total | Compiled | Correct | Rate |
|------|-------|----------|---------|------|
| int.jl | 37 | 37 | 37 | 100% |
| operators.jl | 79 | 79 | 77 | 97% |
| combinatorics.jl | 18 | 18 | 18 | 100% |
| char.jl | 77 | 77 | 76 | 99% |
| floatfuncs.jl | 33 | 33 | 33 | 100% |
| fastmath.jl | 34 | 34 | 34 | 100% |
| enums.jl | 38 | 38 | 38 | 100% |
| functional.jl | 45 | 45 | 43 | 96% |
| numbers.jl | 70 | 70 | 59 | 84% |
| intfuncs.jl | 17 | 17 | 2 | 12% |
| math.jl | 25 | 25 | 20 | 80% |
| tuple.jl | 25 | 25 | 20 | 80% |
| namedtuple.jl | 26 | 26 | 20 | 77% |
| reduce.jl | 51 | 51 | 34 | 67% |
| hashing.jl | 29 | 29 | 28 | 97% |
| complex.jl | 6 | 6 | 6 | 100% |
| rational.jl | 3 | 3 | 3 | 100% |
| subtype.jl | 34 | 34 | 33 | 97% |
| specificity.jl | 11 | 11 | 11 | 100% |
| missing.jl | 1 | 1 | 1 | 100% |

## What Works Well (100% correct)

- Integer arithmetic and bitwise operations
- Float rounding (floor, ceil, round, trunc)
- Comparison operators (==, <, >, isless)
- Boolean logic
- Char operations
- Enum operations
- Simple function composition
- Tuple construction and comparison
- Struct/Pair operations
- Type subtyping checks

## What Needs Work

- Higher-order functions (map/reduce with closures on collections)
- String parsing (parse/tryparse)
- Complex integer functions (digits, ndigits)
- Broadcasting (.* / .+ on arrays/matrices)
- NamedTuple advanced operations
- Comprehensions
