# Getting Started

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/GroupTherapyOrg/WasmTarget.jl")
```

**Requirements:**

- Julia 1.12 (required — IR format is version-specific)
- Node.js 22+ or a WasmGC-capable browser (Chrome 119+, Firefox 120+)

**Optional:**

- [Binaryen](https://github.com/WebAssembly/binaryen) (`wasm-opt`) for optimization
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) for validation

## First Compilation

```julia
using WasmTarget

add(a::Int32, b::Int32)::Int32 = a + b
bytes = compile(add, (Int32, Int32))
write("add.wasm", bytes)
```

```bash
node -e '
  const fs = require("fs");
  WebAssembly.instantiate(fs.readFileSync("add.wasm"))
    .then(m => console.log(m.instance.exports.add(3, 7)));
'
# => 10
```

## Multiple Functions

```julia
square(x::Float64)::Float64 = x * x
cube(x::Float64)::Float64 = x * square(x)

bytes = compile_multi([
    (square, (Float64,)),
    (cube,   (Float64,)),
])
```

Both are exported. `cube` calls `square` inside the module.

## Optimization

```julia
bytes = compile(sin, (Float64,); optimize=true)
```

Requires `wasm-opt` installed. Typical size reduction is 80-90%.
