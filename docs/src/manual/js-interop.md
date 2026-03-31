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
(JavaScript) must provide.

There are two overloads:

- `add_import!(mod, module_name, field_name, params::Vector{NumType}, results::Vector{NumType})`
  for pure numeric signatures (I32, I64, F32, F64 only).
- `add_import!(mod, module_name, field_name, params::Vector{<:WasmValType}, results::Vector{<:WasmValType})`
  for signatures that include reference types like `ExternRef`.

Since `ExternRef` is a `RefType` (not a `NumType`), you must use the
`WasmValType` overload when externref appears in the signature:

```julia
mod = WasmModule()

# Import: dom.set_text(element: externref, text: i32) -> void
# ExternRef is a RefType, so use WasmValType[...] to get the WasmValType overload
add_import!(mod, "dom", "set_text", WasmValType[ExternRef, I32], WasmValType[])

# Import: dom.get_value(element: externref) -> i32
add_import!(mod, "dom", "get_value", WasmValType[ExternRef], WasmValType[I32])

# Pure numeric imports can use plain NumType vectors
add_import!(mod, "math", "add", [I32, I32], [I32])
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

## Manual Vector Bridge (not auto-generated)

When a function operates on `Vector{T}`, JavaScript cannot directly
create WasmGC array references.  You must **manually** compile bridge
functions alongside your code using `compile_multi`.  The compiler does
**not** auto-export `vec_new`/`vec_get`/`vec_set`/`vec_len`.

Define bridge functions that create, read, and write vectors:

```julia
# Your actual function
my_sum(v::Vector{Float64})::Float64 = sum(v)

# Bridge functions — you write these yourself
bv_new(n::Int64)::Vector{Float64} = Vector{Float64}(undef, n)
bv_set!(v::Vector{Float64}, i::Int64, val::Float64)::Int64 = (v[i] = val; Int64(0))
bv_get(v::Vector{Float64}, i::Int64)::Float64 = v[i]
bv_len(v::Vector{Float64})::Int64 = Int64(length(v))

# Compile everything together so they share the same WasmGC type space
bytes = compile_multi([
    (my_sum,  (Vector{Float64},)),
    (bv_new,  (Int64,)),
    (bv_set!, (Vector{Float64}, Int64, Float64)),
    (bv_get,  (Vector{Float64}, Int64)),
    (bv_len,  (Vector{Float64},)),
])
```

The module now exports all five functions:

| Export | Signature | Purpose |
|:-------|:----------|:--------|
| `my_sum` | `(ref) -> f64` | The user function |
| `bv_new` | `(i64) -> ref` | Create vector of given length |
| `bv_get` | `(ref, i64) -> f64` | Get element at index |
| `bv_set!` | `(ref, i64, f64) -> i64` | Set element at index |
| `bv_len` | `(ref) -> i64` | Get vector length |

JavaScript uses these to marshal arrays:

```javascript
const e = instance.exports;
const v = e.bv_new(3n);        // BigInt for i64
e["bv_set!"](v, 1n, 1.0);     // 1-based indexing (Julia)
e["bv_set!"](v, 2n, 2.0);
e["bv_set!"](v, 3n, 3.0);
console.log(e.my_sum(v));      // 6.0
```

This pattern comes from WasmTarget.jl's own test harness
(`test/utils.jl`), which uses the same `compile_multi` approach to
test functions that accept `Vector{Int64}` and `Vector{Float64}`.

## Tables and Indirect Calls

WASM tables (`funcref` / `externref`) enable dynamic dispatch:

```julia
mod = WasmModule()
add_table!(mod, FuncRef, 10)       # Table of 10 function references
add_table!(mod, ExternRef, 5)      # Table of 5 externref slots
add_table!(mod, FuncRef, 4, 16)    # min=4, max=16
```

The signature is `add_table!(mod, reftype::RefType, min, max=nothing)`,
where `reftype` is a `RefType` enum value (`FuncRef` or `ExternRef`),
not a symbol.

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
