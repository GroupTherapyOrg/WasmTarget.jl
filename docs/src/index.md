# WasmTarget.jl

**A Julia-to-WebAssembly compiler targeting WasmGC.**

Compile real Julia functions to WebAssembly that runs in any modern browser or Node.js. No runtime, no LLVM. Inspired by [dart2wasm](https://dart.dev/web/wasm).

## How It Works

Julia's compiler does the heavy lifting — parsing, macro expansion, type inference, optimization. WasmTarget gets the fully type-inferred IR via `Base.code_typed()` and translates it to WasmGC bytecode.

```
Julia source → Julia compiler (parse, lower, infer) → Typed IR → WasmTarget → .wasm
```

For functions with complex IR (GC internals, C library calls, deep dispatch), WasmTarget provides [method overlays](https://github.com/JuliaGPU/GPUCompiler.jl) — the same pattern CUDA.jl uses.

## Current Status

- **176 core Julia functions** compile and produce correct E2E results
- **127 native** (real Base IR), **48 overlay** (pure Julia reimplementations), **1 blocked**
- **2409 tests**, 0 fail, verified across Int32/Int64/UInt32/UInt64/Float32/Float64
- Binaryen optimization: ~85% size reduction, zero regressions
- Nested closures, deep compositions (8+ layers), 20-function modules verified
- Powers [Therapy.jl](https://github.com/GroupTherapyOrg/Therapy.jl) for build-time island compilation

## Quick Example

```julia
using WasmTarget
bytes = compile(sin, (Float64,))
write("sin.wasm", bytes)
```

See [Getting Started](@ref) for installation and more examples.
