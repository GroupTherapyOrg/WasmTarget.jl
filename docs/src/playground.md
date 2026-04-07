# Playground

!!! note "Planned"
    An interactive Julia-to-WASM playground is planned for the future.

In the meantime, compile and run locally:

```julia
using WasmTarget

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
