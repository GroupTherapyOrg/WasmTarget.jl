# WasmTarget.jl

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="logo/wasm_dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="logo/wasm_light.svg">
    <img alt="WasmTarget.jl" src="logo/wasm_light.svg" height="60">
  </picture>

  **A Julia-to-WebAssembly compiler targeting WasmGC.**

  Compile real Julia functions to WebAssembly that runs in any modern browser or Node.js — no runtime, no server, no LLVM.

  Same architecture as [dart2wasm](https://dart.dev/web/wasm) (Dart's official Wasm compiler for Flutter Web).

  [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE.md)
</div>

---

## How It Works

Julia has a 4-stage compiler pipeline: parsing, lowering, type inference, and codegen. WasmTarget replaces the last stage — instead of emitting native machine code via LLVM, it emits WasmGC bytecode.

```
Julia source code
   ↓  Julia's compiler (parsing, lowering, type inference)
Fully typed IR  ←  Base.code_typed()
   ↓  WasmTarget.compile()
.wasm binary    ←  runs in any browser or Node.js
```

Julia's compiler does the hard work — parsing, macro expansion, type inference, optimization. WasmTarget gets fully type-inferred IR and translates it to Wasm instructions. No LLVM involved. Anything Julia can type-infer, WasmTarget can compile.

For functions where the Julia IR is too complex for current codegen (deep dispatch chains, foreigncalls), WasmTarget uses **method overlay tables** — the same infrastructure [CUDA.jl](https://github.com/JuliaGPU/CUDA.jl) and [AMDGPU.jl](https://github.com/JuliaGPU/AMDGPU.jl) use. Julia's own type inference resolves to the overlay *before* codegen sees the IR, so the compiled output is always correct.

### Build-Time Compilation

WasmTarget powers [Therapy.jl](https://github.com/GroupTherapyOrg/Therapy.jl), a reactive web framework. The compilation happens at build time on the dev machine. Only the compiled `.wasm` ships to the browser — no Julia runtime, no interpreter, just fast native Wasm.

```
Dev machine:  Julia code → WasmTarget.jl → .wasm (KB–few MB)
Browser:      Just the compiled .wasm — no Julia runtime needed
```

This is the same model as dart2wasm powering Flutter Web.

## Quick Start

```julia
using WasmTarget

# Any pure Julia function
function add(a::Int32, b::Int32)::Int32
    return a + b
end

# Compile to Wasm
wasm_bytes = compile(add, (Int32, Int32))
write("add.wasm", wasm_bytes)
```

```javascript
// Run in browser or Node.js
const bytes = fs.readFileSync('add.wasm');
const { instance } = await WebAssembly.instantiate(bytes);
console.log(instance.exports.add(5, 3)); // → 8
```

### Multi-function modules

```julia
# Multiple functions with cross-calls, closures, and real Base functions
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

**134 out of 135 core functions compile and produce correct results** — verified by running in Node.js and comparing against native Julia output.

Every function below has been tested E2E: compile to Wasm, validate with `wasm-tools`, execute in Node.js, compare result against native Julia. Tests cover standard args, keyword arguments, closures, and edge cases.

| Category | Working / Total | Coverage | Details |
|:---------|:---------------:|:--------:|:--------|
| **Numeric** | 24 / 24 | **100%** | All native IR. `abs`, `sign`, `clamp`, `min`, `max`, `div`, `mod`, `rem`, `gcd`, `lcm`, `iseven`, `isodd`, `isnan`, `isinf`, `isfinite`, `iszero`, `isone`, `zero`, `one`, `typemin`, `typemax`, `signbit`, `minmax`, `divrem` |
| **Math** | 72 / 72 | **100%** | All native IR. `sin`, `cos`, `exp`, `log`, `sqrt`, `abs`, `floor`, `ceil`, `round`, `trunc` + 62 more transcendental/utility functions |
| **Strings** | 37 / 37 | **100%** | 27 native + 10 overlay. `contains`, `startswith`, `endswith`, `lowercase`, `uppercase`, `strip`, `split`, `join`, `replace`, `repeat`, `reverse`, `titlecase`, `chomp`, `chop`, `lpad`, `rpad`, all `is*` predicates, `cmp`, indexing, SubString |
| **Collections** | 26 / 26 | **100%** | 24 native + 2 overlay. `sort` (all kwargs: `rev`, `by`, `lt`), `filter`, `map`, `reduce`, `sum`, `prod`, `minimum`, `maximum`, `extrema`, `any`, `all`, `count`, `unique`, `reverse`, `accumulate`, `foreach`, `foldl`, `foldr`, `mapreduce`, `findmin`, `findmax`, `argmin`, `argmax` |
| **Array Mutation** | 16 / 16 | **100%** | 7 native + 9 overlay. `push!`, `pop!`, `pushfirst!`, `popfirst!`, `insert!`, `deleteat!`, `append!`, `prepend!`, `splice!`, `resize!`, `empty!`, `fill!`, `copy`, `reverse`, `length`, `vec` |
| **Dict/Set** | 10 / 10 | **100%** | All native IR. `Dict` constructor, `haskey`, `get`, `delete!`, `pop!`, `isempty`, `length`, `Set` + `push!`, `in` |
| **Type Conversion** | 7 / 7 | **100%** | All native IR. `convert`, `sizeof`, `isless`, `cmp`, `string(Int64)` |
| **Iterators** | 14 / 15 | **93%** | All native IR. `collect`, `enumerate`, `zip`, `eachindex`, `pairs`, `Iterators.filter`, `Iterators.map`, `Iterators.flatten`, `Iterators.take`, `Iterators.drop`, `Iterators.takewhile`, `Iterators.dropwhile`, `CartesianIndices`, ranges |
| | **206 / 207** | **99.5%** | Including 72 math functions |

The one blocked function is generator-with-filter syntax (`sum(x for x in v if x > 0)`) — a `Union{_InitialValue, Int64}` null ref edge case. The explicit equivalent `sum(Iterators.filter(x -> x > 0, v))` works perfectly.

### How functions compile: Native IR vs Overlay

Most functions compile directly from Julia's typed IR — the real Base implementation runs as-is in Wasm. For functions where the IR is too complex (GC internals, foreigncalls, deep dispatch), WasmTarget provides **method overlays** — pure Julia reimplementations that produce flat, compilable IR:

```julia
# In src/codegen/interpreter.jl — follows GPUCompiler.jl pattern
@overlay WASM_METHOD_TABLE function Base.sort!(v::AbstractVector;
        lt=isless, by=identity, rev::Bool=false, ...)
    # Simple insertion sort — flat IR, no deep dispatch chains
    n = length(v)
    for i in 2:n
        key = v[i]; j = i - 1
        while j >= 1
            should_shift = rev ? lt(by(v[j]), by(key)) : lt(by(key), by(v[j]))
            !should_shift && break
            v[j + 1] = v[j]; j -= 1
        end
        v[j + 1] = key
    end
    return v
end
```

Julia's `OverlayMethodTable` resolves to these at inference time — codegen never sees the complex original. Each overlay documents *why* it exists and *when* it can be removed as codegen improves.

**Current overlay inventory** (29 total):

| Reason | Count | Functions | Remove when... |
|:-------|:-----:|:----------|:---------------|
| Deep dispatch chains | 4 | `sort!`, `startswith`, `endswith`, `cmp` | Codegen handles method tables |
| Missing inner dispatch | 4 | `chop`, `last(String,Int)`, `reverse(String)`, `titlecase` | Codegen handles method resolution |
| SubString ref cast | 4 | `strip`, `lstrip`, `rstrip`, `replace` | Fix WasmGC type coercion for SubString |
| Codegen stack bug | 2 | `lowercasefirst`, `uppercasefirst` | Fix stack balancing |
| IOBuffer dependency | 1 | `join` | IOBuffer support |
| Self-recursion | 1 | `unique` | Fix function resolution |
| GC/pointer internals | 9 | `push!`, `pop!`, `pushfirst!`, `popfirst!`, `insert!`, `deleteat!`, `append!`, `prepend!`, `splice!` | WasmGC-compatible array mutation IR |
| Complex dispatch | 4 | `split`, + internal helpers | Return type simplification |

## What Compiles

Beyond the 207 audited core functions, WasmTarget handles all the Julia language features needed for real application code:

| Feature | Status | Notes |
|:--------|:------:|:------|
| Integer arithmetic (32/64/128-bit) | **Working** | Including Int128 schoolbook multiply |
| Floating point (32/64-bit) | **Working** | Full IEEE 754 including NaN/Inf |
| Comparisons and boolean logic | **Working** | `&&`, `||`, short-circuit |
| If/else, ternary, while/for | **Working** | All control flow patterns |
| Structs (mutable and immutable) | **Working** | WasmGC structs with field access |
| Tuples and NamedTuples | **Working** | Immutable WasmGC structs |
| Arrays (Vector, Matrix) | **Working** | WasmGC arrays with full mutation |
| Strings | **Working** | As i32 arrays, full operation set |
| Closures | **Working** | Captured variables as WasmGC struct fields |
| Try/catch/throw | **Working** | Wasm `try_table` + `throw` |
| Union{Nothing, T} | **Working** | Tagged union discrimination |
| Multi-function modules | **Working** | Cross-function calls, multiple dispatch |
| JS interop (externref) | **Working** | Import/export, DOM manipulation |
| Wasm globals | **Working** | Mutable state, exported to JS |
| Dict / Set | **Working** | Hash tables with Int/String keys |
| Splatting (f(args...)) | **Working** | Via `_apply_iterate` |
| Broadcasting (.+, .*, etc.) | **Working** | 15/17 patterns |
| Recursive types | **Working** | Self-referential struct trees |

### What won't compile

Things that fundamentally don't exist in a browser:

| Area | Why | Alternative |
|:-----|:----|:------------|
| File system | No FS in browsers | Use JS `fetch()` via imports |
| Networking / sockets | No libuv in Wasm | Use JS `fetch()` via imports |
| Tasks / Threads | Single-threaded Wasm | Use JS async via imports |
| BigInt / BigFloat | GMP/MPFR C libraries | Rare in web apps |
| BLAS / LAPACK | Fortran libraries | Generic Julia matmul works |
| Regex | PCRE2 C library | JS `RegExp` bridge (planned) |

## Architecture

```
src/
├── WasmTarget.jl              # Entry: compile(), compile_multi()
├── builder/                   # Wasm binary format (4 files, ~3K lines)
│   ├── types.jl               #   Type definitions (I32, I64, RefType, etc.)
│   ├── writer.jl              #   Binary serialization (LEB128, sections)
│   ├── instructions.jl        #   Module building, opcodes
│   └── validator.jl           #   Stack validator
├── codegen/                   # Julia IR → Wasm (28 files, ~44K lines)
│   ├── compile.jl             #   Main entry: compile_module, compile_multi
│   ├── interpreter.jl         #   WasmInterpreter + overlay method table
│   ├── statements.jl          #   Statement compilation (~3.5K lines)
│   ├── calls.jl               #   Function call compilation
│   ├── invoke.jl              #   Method dispatch table
│   ├── stackified.jl          #   Structured control flow (stackifier)
│   ├── types.jl               #   TypeRegistry: Julia → WasmGC type mapping
│   └── ...                    #   Context, values, flow, unions, helpers, etc.
└── runtime/                   # Intrinsics and built-in ops (4 files)
    ├── intrinsics.jl          #   Julia intrinsic → Wasm opcode mapping
    ├── stringops.jl           #   String operation intrinsics
    ├── arrayops.jl            #   Array operation intrinsics
    └── simpledict.jl          #   Hash table implementation
```

### Type Mappings

| Julia Type | WebAssembly Type |
|:-----------|:-----------------|
| `Int32`, `UInt32`, `Bool` | `i32` |
| `Int64`, `UInt64`, `Int` | `i64` |
| `Int128`, `UInt128` | WasmGC struct `{i64, i64}` |
| `Float32` | `f32` |
| `Float64` | `f64` |
| `String`, `Symbol` | WasmGC `array<i32>` |
| User structs | WasmGC struct |
| `Tuple{...}` | WasmGC struct (immutable) |
| `Vector{T}` | WasmGC `struct{array_ref, size}` |
| `Matrix{T}` | WasmGC `struct{array_ref, size_tuple}` |
| `Dict{K,V}` | WasmGC struct (hash table) |
| `JSValue` / `Any` | `externref` |

### Testing

Every function is verified by an automated comparison harness that runs the function natively in Julia and in Node.js Wasm, then checks for exact match:

```bash
# Full test suite
julia +1.12 --project=. test/runtests.jl

# Quick verification
julia +1.12 --project=. -e '
  using WasmTarget; include("test/utils.jl")
  r = compare_julia_wasm(x -> x + Int32(1), Int32(5))
  println(r.pass ? "CORRECT" : "MISMATCH: expected=$(r.expected) actual=$(r.actual)")
'
```

## Comparison

| | WasmTarget.jl | dart2wasm | WebAssemblyCompiler.jl |
|:--|:---|:---|:---|
| **Language** | Julia | Dart | Julia |
| **Memory model** | WasmGC | WasmGC | WasmGC via Binaryen |
| **IR source** | `Base.code_typed` | Dart Kernel IR | `Base.code_typed` |
| **Closures** | Working | Working | No |
| **Try/catch** | Working | Working | No |
| **Union types** | Working | Working | No |
| **Method overlays** | GPUCompiler pattern | N/A | N/A |
| **Core function coverage** | 99.5% (207 functions) | Full stdlib | Limited |
| **Production use** | [Therapy.jl](https://github.com/GroupTherapyOrg/Therapy.jl) | Flutter Web | Experimental |

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
