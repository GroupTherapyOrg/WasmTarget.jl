# Playground

!!! note "Coming Soon"
    An interactive Julia-to-WASM compilation playground is planned.  The goal
    is a fully client-side experience: WasmTarget.jl itself compiled to WASM
    running in the browser, so users can write Julia code, compile it, and
    execute the result -- all without a server.

## Try It Now

In the meantime, you can explore live WASM demos embedded in the manual pages:

- [Math Functions](manual/math.md) -- run `sin()` in WASM directly in your browser
- [Collections](manual/collections.md) -- sort and filter examples

Or compile and run locally:

```julia
using WasmTarget

# Compile any function
bytes = compile(sin, (Float64,))
write("sin.wasm", bytes)
```

```bash
node -e '
  const fs = require("fs");
  WebAssembly.instantiate(fs.readFileSync("sin.wasm"))
    .then(m => console.log(m.instance.exports.sin(1.5708)));
'
```

## Architecture (Planned)

The playground will use the same architecture as the
[Rust Playground](https://play.rust-lang.org/):

1. **Compiler in browser**: WasmTarget.jl compiled to WASM via Julia 1.12 trimming
2. **Editor**: CodeMirror with Julia syntax highlighting
3. **Execution**: Compiled output runs immediately in the browser
4. **Zero server dependency**: Everything client-side
