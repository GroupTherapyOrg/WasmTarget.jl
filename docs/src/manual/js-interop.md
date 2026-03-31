# JS Interop

WasmTarget.jl provides several mechanisms for interacting with JavaScript
from compiled WASM modules.

## JSValue (externref)

`JSValue` is a primitive type that maps to WASM's `externref`.  It
represents an opaque handle to any JavaScript value:

```julia
using WasmTarget

# JSValue appears in function signatures
function process(el::JSValue, count::Int32)::Int32
    # el is an opaque JS reference
    return count + Int32(1)
end
```

## Importing JS Functions

Use `add_import!` on a `WasmModule` to declare functions the host
(JavaScript) must provide:

```julia
mod = WasmModule()

# Import: dom.set_text(element: externref, text: i32) -> void
add_import!(mod, "dom", "set_text", [ExternRef, I32], [])

# Import: dom.get_value(element: externref) -> i32
add_import!(mod, "dom", "get_value", [ExternRef], [I32])
```

In JavaScript, provide the imports when instantiating:

```javascript
const imports = {
  dom: {
    set_text: (el, text) => { el.textContent = String(text); },
    get_value: (el) => parseInt(el.value) || 0,
  },
};
const { instance } = await WebAssembly.instantiate(bytes, imports);
```

## Exporting Functions

Compiled functions are automatically exported by name:

```julia
increment(x::Int32)::Int32 = x + Int32(1)
bytes = compile(increment, (Int32,))
# instance.exports.increment(5) => 6
```

Use `compile_multi` with a custom name:

```julia
bytes = compile_multi([
    (increment, (Int32,), "inc"),
])
# instance.exports.inc(5) => 6
```

## WasmGlobal{T, IDX}

`WasmGlobal{T, IDX}` provides type-safe mutable global variables.  The
type parameter `IDX` is the compile-time WASM global index:

```julia
const Counter = WasmGlobal{Int32, 0}
const Threshold = WasmGlobal{Int32, 1}

function increment(g::Counter)::Int32
    g[] = g[] + Int32(1)
    return g[]
end

function check(g::Counter, t::Threshold)::Bool
    return g[] >= t[]
end

bytes = compile_multi([
    (increment, (Counter,)),
    (check, (Counter, Threshold)),
])
```

Key properties:

- **Phantom parameters**: `WasmGlobal` arguments do not become WASM function
  parameters.  `increment(g::Counter)` compiles to a zero-argument WASM function.
- **Auto-created**: The compiler automatically adds globals to the module.
- **Julia-testable**: `g[] = x` and `g[]` work in Julia for testing.
- **Shared state**: Multiple functions in the same `compile_multi` share globals.

## The Bridge Pattern

For functions that operate on `Vector{T}`, the compiler exports factory
and accessor functions alongside the main function:

```julia
my_sum(v::Vector{Float64})::Float64 = sum(v)
bytes = compile(my_sum, (Vector{Float64},))
```

The module exports:

| Export | Signature | Purpose |
|:-------|:----------|:--------|
| `my_sum` | `(ref) -> f64` | The user function |
| `vec_new` | `(i32) -> ref` | Create vector of given length |
| `vec_get` | `(ref, i32) -> f64` | Get element at index |
| `vec_set` | `(ref, i32, f64) -> void` | Set element at index |
| `vec_len` | `(ref) -> i32` | Get vector length |

JavaScript uses these to marshal arrays:

```javascript
const { my_sum, vec_new, vec_get, vec_set } = instance.exports;
const v = vec_new(3);
vec_set(v, 0, 1.0);
vec_set(v, 1, 2.0);
vec_set(v, 2, 3.0);
console.log(my_sum(v)); // 6.0
```

## Tables and Indirect Calls

WASM tables (`funcref` / `externref`) enable dynamic dispatch:

```julia
mod = WasmModule()
add_table!(mod, :funcref, 10)  # Table of 10 function references
```

`call_indirect` looks up a function in the table at runtime.  This is
the foundation for multiple dispatch in WASM.

## Memory and Data Segments

For low-level control, linear memory sections are also available:

```julia
add_memory!(mod, 1)  # 1 page (64KB)
add_data_segment!(mod, 0, UInt8[0x48, 0x65, 0x6c, 0x6c, 0x6f])  # "Hello"
```

Most use cases should prefer WasmGC types (structs, arrays) over linear
memory.
