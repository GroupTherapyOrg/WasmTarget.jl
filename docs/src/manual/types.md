# Type Mappings

WasmTarget.jl maps Julia types to WasmGC types.  The compiler reads the
fully-inferred IR from `Base.code_typed()` and translates each concrete
Julia type to its WASM counterpart.

## Primitive Types

| Julia Type | WASM Type | Notes |
|:-----------|:----------|:------|
| `Int32`, `UInt32` | `i32` | 32-bit integer |
| `Int64`, `UInt64`, `Int` | `i64` | 64-bit integer (`Int` is `Int64` on 64-bit) |
| `Float32` | `f32` | 32-bit float |
| `Float64` | `f64` | 64-bit float |
| `Bool` | `i32` | `0` or `1` |

## Reference Types

| Julia Type | WASM Type | Notes |
|:-----------|:----------|:------|
| `String` | WasmGC `array(i32)` | One i32 per character (Unicode codepoints) |
| `struct Foo ... end` | WasmGC `struct` | Fields map directly |
| `Tuple{A, B, ...}` | WasmGC `struct` | Immutable struct |
| `Vector{T}` | WasmGC `struct{array, length}` | Mutable array with length |
| `Matrix{T}` | WasmGC `struct{array, sizes}` | Data array + size tuple |
| `JSValue` | `externref` | Opaque JS object reference |

## Struct Mapping

Julia structs become WasmGC struct types with fields in declaration order:

```julia
struct Point
    x::Float64
    y::Float64
end
```

Becomes a WasmGC struct type with two `f64` fields.  Mutable structs
(`mutable struct`) work the same way but allow field mutation via
`struct.set`.

## Vector Mapping

`Vector{T}` is represented as a WasmGC struct containing:

1. A WasmGC array of the element type
2. A length field (`i32`)

This mirrors Julia's internal representation and allows efficient
element access and length queries.

## JSValue

`JSValue` is a primitive type that maps to WASM `externref`.  It represents
an opaque handle to a JavaScript value -- a DOM element, a JS object, a
function reference, etc.

```julia
# JSValue appears in function signatures for JS interop
function set_text(el::JSValue, text::Int32)::Nothing
    # Implemented as a WASM import from JS
end
```

See [JS Interop](js-interop.md) for full details.

## WasmGlobal{T, IDX}

`WasmGlobal{T, IDX}` is a type-safe handle for WASM global variables.
The type parameter `T` determines the value type, and `IDX` is the
compile-time global index.  See [JS Interop](js-interop.md) for usage.
