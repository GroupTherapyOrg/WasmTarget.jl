# Structs & Tuples

User-defined structs and tuples compile to WasmGC struct types.

## Structs

```julia
struct Point
    x::Float64
    y::Float64
end

function distance(p::Point)::Float64
    return sqrt(p.x * p.x + p.y * p.y)
end

bytes = compile(distance, (Point,))
```

The compiler automatically registers `Point` as a WasmGC struct type with
two `f64` fields and generates `struct.new` / `struct.get` instructions.

## Mutable Structs

```julia
mutable struct Counter
    value::Int32
end

function increment!(c::Counter)::Int32
    c.value = c.value + Int32(1)
    return c.value
end

bytes = compile(increment!, (Counter,))
```

Mutable struct fields use `struct.set` for assignment.

## Nested Structs

Nested struct types are registered recursively:

```julia
struct Color
    r::Int32
    g::Int32
    b::Int32
end

struct Pixel
    pos::Point
    color::Color
end

function pixel_x(p::Pixel)::Float64
    return p.pos.x
end

bytes = compile(pixel_x, (Pixel,))
```

## Tuples

Tuples compile as immutable WasmGC structs:

```julia
function swap(t::Tuple{Int32, Int32})::Tuple{Int32, Int32}
    return (t[2], t[1])
end

bytes = compile(swap, (Tuple{Int32, Int32},))
```

Each element becomes a struct field.  Index access (`t[1]`, `t[2]`)
compiles to `struct.get` with the appropriate field index.

## Named Tuples

Named tuples work like regular tuples -- field names are erased in the IR:

```julia
function get_name(nt::NamedTuple{(:x, :y), Tuple{Float64, Float64}})::Float64
    return nt.x + nt.y
end
```

## Constructing Structs in WASM

When a function constructs a struct (via `%new` in the IR), the compiler
emits `struct.new`:

```julia
function make_point(x::Float64, y::Float64)::Point
    return Point(x, y)
end

bytes = compile(make_point, (Float64, Float64))
```

## Recursive Structs

Self-referential types are supported:

```julia
mutable struct Node
    value::Int32
    next::Union{Node, Nothing}
end
```

The compiler handles recursive type registration by creating forward
references in the WasmGC type section.
