# WasmTarget.jl

**A Julia-to-WebAssembly compiler targeting WasmGC.**

WasmTarget.jl compiles ordinary Julia functions directly to WebAssembly bytecode.
It hooks into Julia's own compiler via `Base.code_typed()` to obtain fully-typed IR,
then translates that IR into WasmGC instructions -- no intermediate languages, no
external toolchains.  The result is a small `.wasm` binary that runs in any
WasmGC-capable engine (Chrome, Firefox, Node.js 22+).

## Quick Example

```julia
using WasmTarget

# Compile Julia's built-in sin to WebAssembly
bytes = compile(sin, (Float64,))

# Write to disk
write("sin.wasm", bytes)
```

Run it with Node.js:

```bash
node -e '
  const fs = require("fs");
  WebAssembly.instantiate(fs.readFileSync("sin.wasm"))
    .then(m => console.log(m.instance.exports.sin(1.5708)));
'
# => 0.9999999999932537
```

## Feature Highlights

| Capability | Status |
|:-----------|:-------|
| 72/72 Base.Math functions (sin, cos, exp, log, ...) | Compiles correctly |
| 11/12 Base collection functions (sort, filter, map, ...) | Via JS-WasmGC bridge |
| User structs and tuples | WasmGC struct types |
| Closures | Inlined by Julia, compiled |
| JS interop (externref) | Import/export JS objects |
| Mutable global state (WasmGlobal) | For reactive frameworks |
| Multi-function modules | Cross-function calls |
| Exception handling (try/catch/throw) | WasmGC exception tags |
| Union{Nothing, T} discrimination | `isa` + tagged unions |
| Binaryen wasm-opt integration | Production-grade optimization |

## Next Steps

- [Getting Started](@ref) -- install, compile, run
- [Type Mappings](manual/types.md) -- how Julia types map to WASM
- [Math Functions](manual/math.md) -- 72/72 Base.Math compiles
- [API Reference](api.md) -- full public API
