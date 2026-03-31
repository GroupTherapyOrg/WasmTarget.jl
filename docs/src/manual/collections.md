# Collections

WasmTarget.jl supports Julia collection operations through a **JS-WasmGC
bridge pattern**.  Since Julia's `Vector{T}` is represented as a WasmGC
struct (data array + length), the bridge provides factory and accessor
functions that JavaScript can call to marshal data in and out of WASM.

## Supported Functions

**11 out of 12** Base collection functions work correctly:

| Function | Status | Notes |
|:---------|:-------|:------|
| `sort` | Working | In-place sort on WasmGC arrays |
| `filter` | Working | Predicate-based filtering |
| `map` | Working | Transform elements |
| `reduce` | Working | Fold with binary operator |
| `sum` | Working | Sum of elements |
| `prod` | Working | Product of elements |
| `minimum` | Working | Find minimum |
| `maximum` | Working | Find maximum |
| `any` | Working | Test if any element matches |
| `all` | Working | Test if all elements match |
| `count` | Working | Count matching elements |

## The Bridge Pattern

Because WASM modules cannot directly accept or return JavaScript arrays,
WasmTarget.jl exports **factory and accessor functions** alongside the
user's code:

```julia
# User function
my_sum(v::Vector{Float64})::Float64 = sum(v)

# Compiled module exports:
#   my_sum(vec)      -- the actual function
#   vec_new(len)     -- create a new Vector{Float64} of given length
#   vec_get(vec, i)  -- get element at index i
#   vec_set(vec,i,v) -- set element at index i to v
#   vec_len(vec)     -- get length
```

JavaScript uses the factory/accessor exports to build the vector, call
the function, and read results:

```javascript
const { instance } = await WebAssembly.instantiate(bytes);
const { my_sum, vec_new, vec_get, vec_set, vec_len } = instance.exports;

// Build a vector in WASM memory
const v = vec_new(3);
vec_set(v, 0, 1.0);
vec_set(v, 1, 2.0);
vec_set(v, 2, 3.0);

console.log(my_sum(v)); // => 6.0
```

## Example: Sort

```julia
using WasmTarget

function sort_vec(v::Vector{Int32})::Vector{Int32}
    return sort(v)
end

bytes = compile(sort_vec, (Vector{Int32},))
```

## Example: Filter

```julia
function filter_positive(v::Vector{Int32})::Vector{Int32}
    return filter(x -> x > Int32(0), v)
end

bytes = compile(filter_positive, (Vector{Int32},))
```

## Example: Map + Reduce

```julia
function sum_of_squares(v::Vector{Float64})::Float64
    return reduce(+, map(x -> x * x, v))
end

bytes = compile(sum_of_squares, (Vector{Float64},))
```

## Hash Tables

WasmTarget.jl includes two built-in hash table implementations that compile
to WASM:

### SimpleDict (Int32 keys)

```julia
using WasmTarget

function demo_dict()::Int32
    d = sd_new()            # Create empty dict
    sd_set!(d, Int32(1), Int32(100))
    sd_set!(d, Int32(2), Int32(200))
    return sd_get(d, Int32(1))  # => 100
end
```

### StringDict (String keys)

```julia
function demo_string_dict()::Int32
    d = sdict_new()
    sdict_set!(d, "hello", Int32(42))
    return sdict_get(d, "hello")  # => 42
end
```

Both use linear probing and compile entirely to WasmGC operations.
