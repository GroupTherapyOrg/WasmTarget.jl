<div align="center">

# WasmTarget.jl

### Julia-to-WebAssembly Compiler. WasmGC.

Compile real Julia functions to WebAssembly that runs in any modern browser or Node.js. No runtime, no LLVM. Inspired by [dart2wasm](https://dart.dev/web/wasm) (Dart's WasmGC compiler for Flutter Web).

[![CI](https://github.com/GroupTherapyOrg/WasmTarget.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/GroupTherapyOrg/WasmTarget.jl/actions/workflows/ci.yml)
[![Aqua QA](https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![Fuzzy Tests](https://raw.githubusercontent.com/Seelengrab/Supposition.jl/main/badge.svg)](https://github.com/Seelengrab/Supposition.jl)
[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://grouptherapyorg.github.io/WasmTarget.jl/)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE.md)

</div>

## How It Works

Julia has a 4-stage compiler pipeline: parsing, lowering, type inference, and codegen. WasmTarget replaces the last stage — instead of emitting native machine code via LLVM, it emits WasmGC bytecode.

```
Julia source → Julia compiler (parse, lower, infer) → Fully typed IR → WasmTarget → .wasm
```

Julia's compiler does the hard work — parsing, macro expansion, type inference, optimization. WasmTarget gets fully type-inferred IR and translates it. A function reaches Wasm through one of three paths:

1. **Direct compilation.** The function's own typed IR — arithmetic, control flow, loops, structs, tuples, closures, try/catch — translates statement-by-statement to Wasm instructions. This is how *your* code compiles, and how most of Base compiles too, because Julia inlines aggressively: a call like `sum(v)` usually arrives already flattened into plain loops inside the caller's IR.

2. **Closed-world trim collection (the default discovery).** WasmTarget feeds your entry points to the *same* closed-world collection machinery that powers `juliac --trim` upstream (`Compiler.typeinf_ext_toplevel` / `CompilationQueue` — see [JuliaLang/julia#62087](https://github.com/JuliaLang/julia/issues/62087), where this strategy is laid out). The compiler walks every reachable `:invoke` in a single consistent inference world and hands back `(CodeInstance, CodeInfo)` pairs for the whole call graph; WasmTarget compiles each one as its own Wasm function and links the calls. Nothing is hand-curated: `Statistics.quantile`, `sort!` internals, Dict hashing, string search — the entire reachable world is collected the way the compiler itself sees it. The previous curated-whitelist discovery remains available via `compile_multi(...; discovery=:legacy)`.

3. **Method overlays (~100 methods).** For Base methods whose real implementation can't translate — they reach into GC internals, `ccall` into libjulia/libc, use pointer arithmetic, or rely on lookup tables WasmGC can't address — WasmTarget ships replacement implementations via Julia's [`OverlayMethodTable`](https://github.com/JuliaGPU/GPUCompiler.jl), the same mechanism CUDA.jl and AMDGPU.jl use. Overlays are resolved *during inference* — including inside the trim collection — so codegen never sees the original. They are *semantically faithful* substitutes, e.g. `Base.Math.pow_body` is re-implemented as the same compensated power-by-squaring algorithm (bit-identical results), and `reinterpret` becomes a direct `Core.bitcast`.

Where overlays currently live, by area:

| Area | Examples |
|:-----|:---------|
| Array mutation | `push!`, `pop!`, `insert!`, `deleteat!`, `splice!`, `append!`, `copy`, `filter` — WasmGC arrays are fixed-size, so growth is reallocate-and-copy |
| Strings | `split`, `join`, `replace`, `strip` family, `repeat`, `reverse`, `cmp`, `string(::Float64)` (Ryu shortest-round-trip, reimplemented) |
| Math tails | `sinh`/`cosh`/`tanh`/`asin`, `hypot`, `mod`/`rem(::Float64)`, `pow_body`, `Math.table_unpack` (memory-addressed tables → computed) |
| Bit reinterpretation | `reinterpret` between same-width primitives → `Core.bitcast`; shifts on `BitInteger` (Julia over-shift semantics) |
| Reductions | `reduce`/`foldl`/`maximum`/`minimum`/`argmax`/`argmin`/`count` on `Vector` — flat-IR loop forms |
| Dict/Set | `Dict` tuple constructor, `delete!`, `union!` |

Everything not listed compiles from its real Base implementation. The split is verified continuously — see the coverage matrix below.

## Quick Start

```julia
using WasmTarget

function add(a::Int32, b::Int32)::Int32
    return a + b
end

wasm_bytes = compile(add, (Int32, Int32))
write("add.wasm", wasm_bytes)
```

```javascript
import fs from "node:fs";

const bytes = fs.readFileSync("add.wasm");
const { instance } = await WebAssembly.instantiate(bytes);
console.log(instance.exports.add(5, 3)); // → 8
```

Pure numeric kernels compile to **import-free** modules — no server, no bundler,
no imports object. Modules that touch `print`/`show` or string interop do import
the standardized `wasm:js-string` builtins and a small `io` module; instantiate
those with `WebAssembly.instantiate(bytes, imports, { builtins: ['js-string'] })`
— see [Soundness & Testing](#soundness--testing) for the full embedder one-liner.

Multi-function modules with closures and real Base functions:

```julia
f_sort(v::Vector{Int64}) = sort(v, rev=true)
f_filter(v::Vector{Int64}) = filter(iseven, v)
f_map(v::Vector{Int64}) = map(x -> x * 2, v)

bytes = compile_multi([
    (f_sort, (Vector{Int64},)),
    (f_filter, (Vector{Int64},)),
    (f_map, (Vector{Int64},)),
])
```

## What It Powers

WasmTarget compiles real, third-party Julia — not just toy kernels — to interactive WebAssembly that runs entirely client-side:

- **[PlutoIslands.jl](https://github.com/GroupTherapyOrg/PlutoIslands.jl)** turns reactive Pluto notebooks into self-contained WasmGC "islands." The featured-notebook gallery — image processing, 2-D convolution, Mandelbrot/Julia fractals, dithering, Newton's method — recomputes live as you move the sliders, with **no Julia server**. **→ [Live gallery](https://grouptherapyorg.github.io/PlutoIslands.jl/)**
- **[WasmMakie.jl](https://github.com/GroupTherapyOrg/WasmMakie.jl)** compiles a Makie-style plotting API (`lines!`, `scatter!`, `image!`, `heatmap!`) to an HTML canvas through WasmTarget.
- **[Therapy.jl](https://github.com/GroupTherapyOrg/Therapy.jl)** is a web framework that compiles `@island` components at build time.

These double as integration tests: every release is re-checked against the full featured-notebook corpus, so "compiles real Julia" stays true rather than aspirational.

## Coverage

Coverage is tracked by a **differential fuzzer**, not a hand-maintained list. The fuzzer holds a catalogue of ~590 Base operation signatures across these areas:

| Area | What's covered |
|:-----|:---------------|
| Numeric | `abs`, `sign`, `clamp`, `min`/`max`, `div`/`mod`/`rem`/`divrem`, `gcd`/`lcm`, predicates (`iseven`, `isnan`, …), `typemin`/`typemax`, checked arithmetic, 8/16/32/64/128-bit widths |
| Math | trig/hyperbolic/inverse families, `exp`/`log` families, `sqrt`/`cbrt`/`hypot`, rounding, `^` (float and integer, correctly rounded), `Float32` and `Float64` |
| Strings | indexing, search (`contains`, `findnext`, …), case transforms, `split`/`join`/`replace`, padding, `string(::Int)`/`string(::Float64)` round-trips, `Char` predicates |
| Collections | `sort`, `map`/`filter`/`reduce`/`mapreduce`, `sum`/`prod`/`extrema`, `any`/`all`/`count`, `unique`, `accumulate`/`cumsum`, `findmax`/`argmax` |
| Array mutation | `push!`/`pop!`/`pushfirst!`/`popfirst!`, `insert!`/`deleteat!`/`splice!`, `append!`/`prepend!`, `fill!`/`empty!`/`resize!`, mutation parity checked against native |
| Dict/Set | construction, `setindex!`/`getindex`/`get`, `haskey`/`in`, `delete!`/`pop!`, `Set` ops, with `Int`/`String`/`Float` keys |
| Iterators | `collect`, `enumerate`, `zip`, `pairs`, `Iterators.take`/`drop`/`filter`/`map`/`flatten`, ranges |
| Control flow | nested if/else, while loops with accumulators, try/catch/finally (including nested chains), early returns, closures over all of the above |

Every signature's status lives in [`test/fuzz/COVERAGE.md`](test/fuzz/COVERAGE.md), regenerated from fuzzing runs: an entry is `pass` only when it appears in at least one randomly-generated program whose Wasm output **matched native Julia exactly** — value, thrown-ness, and argument mutations. Current matrix: **all 588 entries pass**, with **0 silent divergences** — every known unsupported construct fails *loudly* (a compile error or a trap), never miscompiles. The ledger in [`test/fuzz/failures/`](test/fuzz/failures/) holds 240+ caught-and-shrunk divergence postmortems, each a self-reproducing case that auto-closes when fixed. A bounded `discovery_differential()` additionally cross-checks the trim and legacy pipelines against each other on generated programs.

## Standard Library Integrations

Stdlib support ships as zero-dependency [package extensions](https://pkgdocs.julialang.org/v1/creating-packages/#Conditional-loading-of-code-in-packages-(Extensions)) (weakdeps) — loading the stdlib activates the extension, nothing is required otherwise. Every supported name is one of two things, never asserted:

- **(A) compiled from its real implementation** and confirmed by a differential sweep (Wasm vs native, the same tolerance/bit-exact oracle as core); or
- **(B) rerouted through a bit-exact `@overlay`** when the real implementation reaches code WasmGC can't lower (BLAS/LAPACK `ccall`s, SIMD intrinsics, dimension-reduction machinery) — a *semantically identical* substitute, proven equivalent before it ships.

Support is tracked the same way Base is: a **grounded percentage over the full `names(Stdlib)` surface** (out-of-scope = genuinely non-Wasm, e.g. host entropy / packed BLAS forms), regenerated from differential runs into [`test/fuzz/STDLIB_COVERAGE.md`](test/fuzz/STDLIB_COVERAGE.md).

| Stdlib | In-scope support | Highlights | Notes |
|:-------|:-----------------|:-----------|:------|
| `Statistics` | **100%** | `mean`/`var`/`std`/`cor`/`median`/`quantile` + in-place `mean!`/`median!`/`quantile!` | bit-exact vs native, both Julia versions |
| `LinearAlgebra` | **97%** | `det`/`inv`/`\`/`norm`/`dot`/`cross`, factorization **objects** `lu`/`cholesky`/`eigen`/`svd` (+ `eigvals`/`svdvals`/`pinv`/`cond`), structured types (`Diagonal`/`Symmetric`/`Triangular`/…), in-place `mul!`/`ldiv!`/`rdiv!`/`kron!`/`triu!`/… | factorizations hand-rolled (LU / cyclic-Jacobi / one-sided-Jacobi) where BLAS/LAPACK can't lower, reconstruction-verified; `qr`/`schur`/`lq`/general & complex eigen out of scope |
| `Dates` | **96%** | construction (`Date`/`DateTime`/`Time`), arithmetic, accessors, conversions (`datetime2unix`↔`unix2datetime`, `…2julian`/`…2rata`), `dayname`/`monthname`, adjusters (`tonext`/`toprev`/`tofirst`/`tolast`), `string` rendering | `format` (the `DateFormat` DSL) and `canonicalize` pending; `now`/`today` need host time |
| `Random` | **100%** *(Julia ≤1.12)* | seeded `Xoshiro`: `rand`/`randn`/`randexp`, `randperm`/`randcycle`/`shuffle` (+ `!`-variants), `seed!`, `randsubseq`/`randsubseq!`, `randstring` | the seeded-RNG differential is a valid oracle on ≤1.12; on 1.13-rc1 Xoshiro seeding was reworked and the stream is platform-unstable, so the suite is gated there. Out of scope: `rand!`/`randn!`/`randexp!` array fills (8-lane SIMD `llvmcall`), `bitrand` (`BitVector`), OS entropy |
| `SparseArrays` | **100%** | `SparseMatrixCSC` construction, `nnz`/`nonzeros`/`rowvals`/`findnz`/`nzrange`, reductions, `sparse·vector`/`sparse·sparse` (**matmul**), `+`/`-`, `transpose`/`permute`, `spdiagm`/`spzeros`/`hcat`/`vcat`/`blockdiag`, `dropzeros!`/`droptol!`/`fkeep!` — plus multi-op combos (`A*B+Cᵀ`, …) to prove composition | unlocked by registering `SparseMatrixCSC` as a real struct (not WT's array layout) + textbook-CSC ext overlays; `sparse`-direct `\`/factorizations out of scope (SuiteSparse C library), `sprand`/`sprandn` (RNG consumption diverges) |

Two things make this cheap. The **trim collection** compiles things like `quantile` (which needs `sort!` internals, kwarg bodies, and `Core.kwcall`) with zero special-casing. And the differential oracle is **tolerance-aware**, so a hand-rolled factorization that differs from BLAS only by reassociation rounding still validates as correct against native. Per-stdlib ledgers (what's verified, what's overlaid, what's out-of-scope and *why*) live in [`test/fuzz/FINDINGS.md`](test/fuzz/FINDINGS.md).

## Language Features

| Feature | Status |
|:--------|:------:|
| Integer arithmetic (8/16/32/64/128-bit, Julia wrap/over-shift semantics) | Working |
| Floating point (32/64-bit, IEEE 754, correctly-rounded `^`) | Working |
| Control flow (if/else, while, for) | Working |
| Structs (mutable and immutable) | Working |
| Tuples and NamedTuples | Working |
| Arrays (Vector, Matrix) | Working |
| Strings (UTF-8) | Working |
| Closures (including closures over Dicts/Vectors, passed to higher-order functions) | Working |
| Exceptions: try/catch/finally, nested chains, catchable Base errors (`BoundsError`, `DivideError`, `DomainError`, `OverflowError`, `InexactError`, …) | Working |
| Union{Nothing, T} and small unions | Working |
| Multi-function modules | Working |
| JS interop (externref) | Working |
| Dict / Set | Working |
| Splatting (f(args...)) | Working |
| Keyword arguments | Working |

### Known limitations

Constructs whose **inferred type is abstract** (requiring runtime type
dispatch) are not supported and trap or raise a compile error:

- **Heterogeneous-key `Dict` literals** — `Dict(Int32(0) => 0, some_int64 => 0)`
  promotes through `dict_with_eltype`, inferring an unparameterized `Dict`.
  Promote keys explicitly so all pairs share one concrete type.
- **Mixed `Char`/`String`/`SubString` varargs beyond two arguments** — the
  vararg tuple's elements widen to a `Union`; two-argument combinations are
  covered by concrete overlay specializations.
- **Matrix literals of tuples** (`[(a,b) (c,d); …]`) — the `hvncat` machinery
  currently recurses in compilation; build with `Matrix{T}(undef, m, n)` and
  explicit stores instead.

## Type Mappings

| Julia Type | WebAssembly Type |
|:-----------|:-----------------|
| `Int32`, `UInt32`, `Bool` | `i32` |
| `Int64`, `UInt64` | `i64` |
| `Float32` | `f32` |
| `Float64` | `f64` |
| `String` | WasmGC packed `(array (mut i8))` (UTF-8 bytes; `array.get_u` widens to i32 on the stack) |
| User structs | WasmGC struct |
| `Vector{T}` | WasmGC `struct{array_ref, size}` |
| `Dict{K,V}` | WasmGC struct (hash table) |
| `JSValue` | `externref` |

## Soundness & Testing

WasmTarget aims to be **correct-or-loud, never silently wrong**.

**`strict=true` (default).** When codegen meets a construct it cannot lower to a
faithful result, `compile` raises a `WasmCompileError` naming the construct and its
source location instead of silently emitting a trap. This covers both *wrong-value*
stubs (e.g. `objectid`, a non-zero `memset`) and *genuinely-unsupported operations*
that would otherwise return a value natively (128-bit checked arithmetic, raw
`pointerset`, `Core.svec`, `:new` of a non-constant type, a numeric op on a boxed/
`Any` operand, …) — the guiding principle is **narrow-but-bulletproof: if it
compiles, it's faithful to the Julia; if it can't, it tells you, up front.** Julia
exceptions compile to *catchable* Wasm exceptions (a shared exception tag), so
`try`/`catch` over throwing Base code behaves like native; ubiquitous dead
error-arms (`@boundscheck`/DomainError that the IR can't prove dead) keep a sound
silent trap rather than rejecting most of `Base`. Pass `strict=false` for permissive
stub-and-trap.

```julia
compile(f, (T,))                 # strict + validated (default)
compile(f, (T,); strict=false)   # permissive: emit runtime-trap stubs
```

**Author pre-flight (optional).** Because WasmTarget rejects type-unstable / boxed /
dynamically-dispatched code rather than guessing, the fastest way to know a function
is in-subset *before* compiling is to check it for type stability and dynamic
dispatch with the standard Julia tooling — [JET.jl](https://github.com/aviatesk/JET.jl)
(`@report_call`), [AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl)
(`@check_allocs` flags object creation **and dynamic dispatch**), or
[DispatchDoctor.jl](https://github.com/MilesCranmer/DispatchDoctor.jl) (`@stable`).
WasmTarget ships none of this machinery itself; these are author-side linters that
make code "stricter" in exactly the way the compiler wants.

**`validate=true` (default).** Every compiled module is checked with
`wasm-tools validate`; a reject raises `WasmValidationError` rather than handing
back malformed bytes.

**`discovery=:trim` (default).** Callee discovery uses the upstream closed-world
trim collection; pass `discovery=:legacy` for the previous curated-whitelist
walker. Because the trim collection compiles the *full* reachable world
(including print/show paths), emitted modules may import the standardized
`wasm:js-string` builtins and a small `io` module — embedders should instantiate
with `WebAssembly.instantiate(bytes, imports, { builtins: ['js-string'] })` and
may stub the `io` functions (`write_string`, `write_int`, `write_float`,
`write_bool`, `write_newline`, `write_nothing`).

**Differential fuzzing.** `test/fuzz/` generates *well-typed* random compositions of
Base functions — expressions, statements, loops, try/catch, closures, structs — and
checks each against native Julia (native is both oracle and validity filter):
same value, same throw, same argument mutations, bit-exact across a Node.js bridge.
Findings are auto-shrunk to a minimal reproducer, persisted to a
[Supposition.jl](https://github.com/Seelengrab/Supposition.jl) corpus (replayed
first on every run as a regression ratchet), and documented as self-reproducing
"gap" files that auto-close when fixed. A bounded pass runs in CI; deep exploration
runs standalone:

```bash
julia --project=test/fuzz test/fuzz/run.jl sweep     # parallel discovery (time-boxed)
julia --project=test/fuzz test/fuzz/run.jl verify    # re-check open gaps, auto-close fixed
julia --project=test/fuzz test/fuzz/run.jl coverage  # regenerate COVERAGE.md
```

## Requirements

- **Julia 1.12 or 1.13** (required — the typed-IR format is version-specific, so each minor line is supported explicitly; both run in CI)
- Node.js 20+ for testing (WasmGC support)
- `wasm-tools` for validation (`cargo install wasm-tools`)

## Installation

```julia
using Pkg
Pkg.add("WasmTarget")
```

## License

Apache License 2.0 — see [LICENSE.md](LICENSE.md)
