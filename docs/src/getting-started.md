# Getting Started

## Installation

WasmTarget.jl is not yet in the Julia General registry.  Install from GitHub:

```julia
using Pkg
Pkg.add(url="https://github.com/GroupTherapyOrg/WasmTarget.jl")
```

**Requirements:**

- Julia 1.12+ (uses pure-Julia math intrinsics, no foreigncalls)
- Node.js 22+ or a WasmGC-capable browser (Chrome 119+, Firefox 120+) to run output

**Optional (for optimization):**

- [Binaryen](https://github.com/WebAssembly/binaryen) (`wasm-opt`) -- `brew install binaryen` or `apt install binaryen`
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) -- for validation

## First Compilation

Compile a simple function to WebAssembly:

```julia
using WasmTarget

# Any ordinary Julia function works
add(a::Int32, b::Int32)::Int32 = a + b

# Compile to WASM bytes
bytes = compile(add, (Int32, Int32))

# Write the binary
write("add.wasm", bytes)
println("Compiled $(length(bytes)) bytes")
```

## Running in Node.js

```bash
node -e '
  const fs = require("fs");
  WebAssembly.instantiate(fs.readFileSync("add.wasm"))
    .then(m => console.log(m.instance.exports.add(3, 7)));
'
# => 10
```

## Multiple Functions

Use `compile_multi` to compile several functions into a single WASM module.
Functions can call each other:

```julia
square(x::Float64)::Float64 = x * x

function cube(x::Float64)::Float64
    return x * square(x)
end

bytes = compile_multi([
    (square, (Float64,)),
    (cube,   (Float64,)),
])

write("math.wasm", bytes)
```

Both `square` and `cube` are exported.  `cube` calls `square` inside the module.

## Optimization

Pass `optimize=true` to run Binaryen's `wasm-opt` with dart2wasm production flags:

```julia
bytes = compile(sin, (Float64,); optimize=true)
```

Optimization levels:

| Value | Flag | Description |
|:------|:-----|:------------|
| `false` | -- | No optimization (default) |
| `true` | `-Os` | Size-optimized (dart2wasm defaults) |
| `:speed` | `-O3` | Speed-optimized |
| `:debug` | `-O1` | Light optimization, no `--traps-never-happen` |

## What's Next

- [Type Mappings](manual/types.md) -- understand how Julia types become WASM types
- [Math Functions](manual/math.md) -- all 72 Base.Math functions compile
- [Collections](manual/collections.md) -- sort, filter, map via JS bridge
- [JS Interop](manual/js-interop.md) -- externref, imports, exports, globals
