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

1. **Direct compilation (the default).** The function's own typed IR — arithmetic, control flow, loops, structs, tuples, closures, try/catch — translates statement-by-statement to Wasm instructions. This is how *your* code compiles, and how most of Base compiles too, because Julia inlines aggressively: a call like `sum(v)` usually arrives already flattened into plain loops inside the caller's IR.

2. **Auto-discovered callees.** When a Base call is too large to inline, it stays in the IR as a real `:invoke`. WasmTarget walks these, compiles each callee as its own Wasm function from *its* typed IR, and links the calls — recursively. A curated whitelist controls which Base internals are eligible (Dict hashing, sorting internals, checked arithmetic, string search, integer parsing, …), so a single `Dict(k => v)` in your code transparently pulls in and compiles the real `ht_keyindex2_shorthash!` from Base.

3. **Method overlays (~100 methods).** For Base methods whose real implementation can't translate — they reach into GC internals, `ccall` into libjulia/libc, use pointer arithmetic, or rely on lookup tables WasmGC can't address — WasmTarget ships replacement implementations via Julia's [`OverlayMethodTable`](https://github.com/JuliaGPU/GPUCompiler.jl), the same mechanism CUDA.jl and AMDGPU.jl use. Overlays are resolved during inference, so codegen never sees the original. They are *semantically faithful* substitutes, e.g. `Base.Math.pow_body` is re-implemented as the same compensated power-by-squaring algorithm (bit-identical results), and `reinterpret` becomes a direct `Core.bitcast`.

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
const bytes = fs.readFileSync('add.wasm');
const { instance } = await WebAssembly.instantiate(bytes);
console.log(instance.exports.add(5, 3)); // → 8
```

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

Every signature's status lives in [`test/fuzz/COVERAGE.md`](test/fuzz/COVERAGE.md), regenerated from fuzzing runs: an entry is `pass` only when it appears in at least one randomly-generated program whose Wasm output **matched native Julia exactly** — value, thrown-ness, and argument mutations. Current matrix: **588 of 589 entries pass** (the remainder unsampled in the last run, not failing), with **0 known divergences** and 179 fixed-divergence postmortems in [`test/fuzz/failures/`](test/fuzz/failures/).

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

**`strict=true` (default).** When codegen meets a construct that would compile to a
*wrong value* (e.g. `objectid`, a non-zero `memset`), `compile` raises a
`WasmCompileError` naming the construct and its source location instead of emitting
it. Julia exceptions compile to *catchable* Wasm exceptions (a shared exception
tag), so `try`/`catch` over throwing Base code behaves like native; only genuinely
unsupported constructs trap. Pass `strict=false` for permissive stub-and-trap.

```julia
compile(f, (T,))                 # strict + validated (default)
compile(f, (T,); strict=false)   # permissive: emit runtime-trap stubs
```

**`validate=true` (default).** Every compiled module is checked with
`wasm-tools validate`; a reject raises `WasmValidationError` rather than handing
back malformed bytes.

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
