<div align="center">

# WasmTarget.jl

### Julia-to-WebAssembly Compiler. WasmGC.

Compile real Julia functions to WebAssembly that runs in any modern browser or Node.js. No runtime, no LLVM. Inspired by [dart2wasm](https://dart.dev/web/wasm) (Dart's WasmGC compiler for Flutter Web).

[![CI](https://github.com/GroupTherapyOrg/WasmTarget.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/GroupTherapyOrg/WasmTarget.jl/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://grouptherapyorg.github.io/WasmTarget.jl/)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE.md)

</div>

## How It Works

Julia has a 4-stage compiler pipeline: parsing, lowering, type inference, and codegen. WasmTarget replaces the last stage — instead of emitting native machine code via LLVM, it emits WasmGC bytecode.

```
Julia source → Julia compiler (parse, lower, infer) → Fully typed IR → WasmTarget → .wasm
```

Julia's compiler does the hard work — parsing, macro expansion, type inference, optimization. WasmTarget gets fully type-inferred IR and translates it to Wasm instructions. For functions where the IR is straightforward (arithmetic, control flow, structs, closures), compilation is direct. For functions with complex IR patterns (GC internals, C library calls, deep dispatch chains), WasmTarget provides [method overlays](https://github.com/JuliaGPU/GPUCompiler.jl) — the same pattern CUDA.jl uses — that give Julia's inference a simpler path to resolve before codegen runs.

Coverage is growing. 176 core Base functions work today (see tables below). The goal is for any pure Julia function to compile — we're not there yet, but the foundation is solid.

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

## Core Julia Function Coverage

**176 core functions compile and produce correct E2E results.** 1793 tests, 0 broken.

Every function is verified: compile to Wasm, validate with `wasm-tools`, execute in Node.js, compare against native Julia.

### Numeric (24/24)

| Function | Path | Status |
|:---------|:-----|:-------|
| `abs` (Int64, Float64) | Native | Working |
| `sign` (Int64, Float64) | Native | Working |
| `signbit` (Int64, Float64) | Native | Working |
| `clamp` (Int64, Float64) | Native | Working |
| `min` (Int64, Float64) | Native | Working |
| `max` (Int64, Float64) | Native | Working |
| `minmax` | Native | Working |
| `div` | Native | Working |
| `mod` (Int64) | Native | Working |
| `rem` (Int64) | Native | Working |
| `divrem` | Native | Working |
| `gcd` | Overlay | Working |
| `lcm` | Overlay | Working |
| `iseven` | Native | Working |
| `isodd` | Native | Working |
| `isnan` | Native | Working |
| `isinf` | Native | Working |
| `isfinite` | Native | Working |
| `iszero` | Native | Working |
| `isone` | Native | Working |
| `zero` | Native | Working |
| `one` | Native | Working |
| `typemin` | Native | Working |
| `typemax` | Native | Working |

### Math (43/43)

| Function | Path | Status |
|:---------|:-----|:-------|
| `sin`, `cos`, `tan` | Native | Working |
| `asin`, `acos`, `atan` | Native | Working |
| `sinh`, `cosh`, `tanh` | Native | Working |
| `exp`, `log`, `log2`, `log10` | Native | Working |
| `log1p`, `expm1`, `exp2` | Native | Working |
| `sqrt`, `cbrt`, `hypot` | Native | Working |
| `sincos`, `sinpi`, `cospi`, `tanpi` | Native | Working |
| `sinc`, `cosc`, `modf` | Native | Working |
| `ldexp`, `mod2pi` | Native | Working |
| `deg2rad`, `rad2deg` | Native | Working |
| `floor`, `ceil`, `round`, `trunc` | Native | Working |
| `fourthroot`, `copysign` | Native | Working |
| `Float64^Float64`, `Float64^Int` | Native | Working |
| `mod` (Float64), `rem` (Float64) | Overlay | Working |

### Strings (37/37)

| Function | Path | Status |
|:---------|:-----|:-------|
| `length`, `ncodeunits` | Native | Working |
| `contains`, `occursin` | Native | Working |
| `startswith`, `endswith` | Overlay | Working |
| `nextind`, `prevind`, `thisind` | Native | Working |
| `lowercase`, `uppercase` | Native | Working |
| `cmp`, `reverse` (String) | Overlay | Working |
| `chomp`, `chopprefix`, `chopsuffix` | Native | Working |
| `chop`, `last` (String, Int) | Overlay | Working |
| `split`, `replace`, `join` | Overlay | Working |
| `lpad`, `rpad` | Native | Working |
| `isdigit`, `isspace` | Native | Working |
| `isletter`, `isuppercase`, `islowercase`, `isascii` | Overlay | Working |
| `titlecase`, `lowercasefirst`, `uppercasefirst` | Overlay | Working |
| `strip`, `lstrip`, `rstrip` | Overlay | Working |
| `repeat`, `string` (Int64) | Overlay | Working |

### Collections (26/26)

| Function | Path | Status |
|:---------|:-----|:-------|
| `sort`, `sort!`, `filter` | Overlay | Working |
| `map`, `reduce`, `foldl`, `foldr` | Native | Working |
| `sum`, `prod` | Native | Working |
| `minimum`, `maximum`, `extrema` | Native | Working |
| `any`, `all` | Native | Working |
| `count`, `unique`, `foreach` | Overlay | Working |
| `reverse` (Vector), `accumulate` | Native | Working |
| `findmax`, `findmin`, `mapreduce` | Native | Working |
| `argmax`, `argmin` | Overlay | Working |

### Array Mutation (16/16)

| Function | Path | Status |
|:---------|:-----|:-------|
| `push!`, `pop!`, `pushfirst!`, `popfirst!` | Overlay | Working |
| `insert!`, `deleteat!`, `splice!` | Overlay | Working |
| `append!`, `prepend!` | Overlay | Working |
| `empty!`, `fill!`, `copy` | Overlay | Working |
| `resize!`, `reverse`, `length`, `vec` | Native | Working |

### Dict/Set (10/10)

| Function | Path | Status |
|:---------|:-----|:-------|
| `Dict()` + `setindex!`, `haskey`, `get` | Native | Working |
| `delete!`, `pop!`, `isempty`, `length` | Native | Working |
| `Set()` + `push!`, `in` | Native | Working |

### Iterators (14/15)

| Function | Path | Status |
|:---------|:-----|:-------|
| `collect`, `enumerate`, `zip`, `eachindex`, `pairs` | Native | Working |
| `Iterators.filter`, `.map`, `.flatten` | Native | Working |
| `Iterators.take`, `.drop`, `.takewhile`, `.dropwhile` | Native | Working |
| `CartesianIndices`, ranges | Native | Working |
| Generator-with-filter | — | Blocked |

### Type Conversion (5/5)

| Function | Path | Status |
|:---------|:-----|:-------|
| `convert`, `sizeof` | Native | Working |
| `isless` (Int64) | Native | Working |
| `isless` (Float64), `cmp` (String) | Overlay | Working |

### Summary

| Category | Total | Native | Overlay | Broken |
|:---------|------:|-------:|--------:|-------:|
| Numeric | 24 | 22 | 2 | 0 |
| Math | 43 | 41 | 2 | 0 |
| Strings | 37 | 17 | 20 | 0 |
| Collections | 26 | 16 | 10 | 0 |
| Array Mutation | 16 | 4 | 12 | 0 |
| Type Conversion | 5 | 3 | 2 | 0 |
| Dict/Set | 10 | 10 | 0 | 0 |
| Iterators | 15 | 14 | 0 | 1 |
| **Total** | **176** | **127 (72%)** | **48 (27%)** | **1** |

23/23 cross-path composition tests pass — native and overlay functions compose correctly through Julia's inference system.

## Native IR vs Overlay

Most functions compile directly from Julia's typed IR — the real Base implementation runs as-is in Wasm. For functions where the IR is too complex (GC internals, foreigncalls, deep dispatch), WasmTarget provides **method overlays** — the same [GPUCompiler.jl](https://github.com/JuliaGPU/GPUCompiler.jl) pattern that CUDA.jl and AMDGPU.jl use:

```julia
@overlay WASM_METHOD_TABLE function Base.sort!(v::AbstractVector;
        lt=isless, by=identity, rev::Bool=false, ...)
    # Simple insertion sort — flat IR, no deep dispatch chains
    ...
end
```

Julia's `OverlayMethodTable` resolves overlays at inference time. Codegen never sees the complex original.

## Language Features

| Feature | Status |
|:--------|:------:|
| Integer arithmetic (32/64/128-bit) | Working |
| Floating point (32/64-bit, IEEE 754) | Working |
| Control flow (if/else, while, for) | Working |
| Structs (mutable and immutable) | Working |
| Tuples and NamedTuples | Working |
| Arrays (Vector, Matrix) | Working |
| Strings | Working |
| Closures | Working |
| Try/catch/throw | Working |
| Union{Nothing, T} | Working |
| Multi-function modules | Working |
| JS interop (externref) | Working |
| Dict / Set | Working |
| Splatting (f(args...)) | Working |

## Type Mappings

| Julia Type | WebAssembly Type |
|:-----------|:-----------------|
| `Int32`, `UInt32`, `Bool` | `i32` |
| `Int64`, `UInt64` | `i64` |
| `Float32` | `f32` |
| `Float64` | `f64` |
| `String` | WasmGC `array<i32>` |
| User structs | WasmGC struct |
| `Vector{T}` | WasmGC `struct{array_ref, size}` |
| `Dict{K,V}` | WasmGC struct (hash table) |
| `JSValue` | `externref` |

## Requirements

- **Julia 1.12** (required — IR format is version-specific)
- Node.js 20+ for testing (WasmGC support)
- `wasm-tools` for validation (`cargo install wasm-tools`)

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/GroupTherapyOrg/WasmTarget.jl")
```

## License

Apache License 2.0 — see [LICENSE.md](LICENSE.md)
