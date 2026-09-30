# Wasm Types - Value types, Reference types, and composite types
# Reference: https://webassembly.github.io/spec/core/binary/types.html

export NumType, RefType, ConcreteRef, NonNullAbstractRef, FuncType, StructType, ArrayType, FieldType, CompositeType, WasmValType, JSValue, WasmGlobal

# ============================================================================
# Value Types (Section 5.3.1)
# ============================================================================

"""
    NumType

Numeric types in WebAssembly.
"""
@enum NumType::UInt8 begin
    I32 = 0x7F  # i32
    I64 = 0x7E  # i64
    F32 = 0x7D  # f32
    F64 = 0x7C  # f64
end

"""
    RefType

Reference types in WebAssembly (including WasmGC extensions).
"""
@enum RefType::UInt8 begin
    FuncRef = 0x70    # funcref
    ExternRef = 0x6F  # externref
    AnyRef = 0x6E     # anyref (WasmGC)
    EqRef = 0x6D      # eqref (WasmGC)
    I31Ref = 0x6C     # i31ref (WasmGC)
    StructRef = 0x6B  # structref (WasmGC)
    ArrayRef = 0x6A   # arrayref (WasmGC)
    ExnRef = 0x69     # exnref (exception handling)
end

"""
    ConcreteRef

A concrete reference type with a type index, e.g., `(ref null \$typeidx)`.
Used for locals and parameters that hold instances of specific struct/array types.
parity(pkg/wasm_builder/lib/src/ir/type.dart:164 RefType)
"""
struct ConcreteRef
    type_idx::UInt32
    nullable::Bool
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:164 RefType)
ConcreteRef(type_idx::UInt32)::ConcreteRef = ConcreteRef(type_idx, true)  # Default nullable

"""
    NonNullAbstractRef

A non-nullable reference to an abstract heap type, e.g., `(ref extern)` or `(ref func)`.
RefType values like ExternRef (0x6F) are always nullable shorthand; this type
expresses the non-null variant needed for some import signatures (e.g., JS String Builtins).
parity(pkg/wasm_builder/lib/src/ir/type.dart:164 RefType)
"""
struct NonNullAbstractRef
    heaptype_byte::UInt8  # Same byte as the RefType enum: 0x6F for extern, 0x70 for func, etc.
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:185 RefType.extern)
const NonNullExternRef = NonNullAbstractRef(UInt8(ExternRef))  # (ref extern)
# parity(pkg/wasm_builder/lib/src/ir/type.dart:195 RefType.func)
const NonNullFuncRef = NonNullAbstractRef(UInt8(FuncRef))      # (ref func)

"""
    WasmValType

Union type for all Wasm value types (numeric, reference, packed, concrete refs).
parity(pkg/wasm_builder/lib/src/ir/type.dart:39 ValueType)
"""
const WasmValType = Union{NumType, RefType, ConcreteRef, NonNullAbstractRef, UInt8}

# ============================================================================
# Function Types (Section 5.3.6)
# ============================================================================

"""
    FuncType

A function type describing the signature of a WebAssembly function.
Supports both numeric types and reference types (for WasmGC).
parity(pkg/wasm_builder/lib/src/ir/type.dart:974 FunctionType)
"""
struct FuncType
    params::Vector{WasmValType}
    results::Vector{WasmValType}
end

# Convenience constructor for NumType-only signatures
# parity(pkg/wasm_builder/lib/src/ir/type.dart:974 FunctionType)
FuncType(params::Vector{NumType}, results::Vector{NumType})::FuncType =
    FuncType(WasmValType[p for p in params], WasmValType[r for r in results])

# ============================================================================
# WasmGC Types
# Reference: https://github.com/WebAssembly/gc/blob/main/proposals/gc/Overview.md
# ============================================================================

"""
    FieldType

A field in a WasmGC struct type.
parity(pkg/wasm_builder/lib/src/ir/type.dart:1338 FieldType)
"""
struct FieldType
    valtype::WasmValType  # The type of the field
    mutable_::Bool        # Whether the field is mutable
    # a field's storage type is a value type or a packed i8/i16 (dart's StorageType); a raw byte
    # standing for a reference type (0x70 for funcref) encodes the same bytes but is not a
    # reference to the builder, which then cannot check what the field holds
    function FieldType(valtype::WasmValType, mutable_::Bool)::FieldType
        (valtype isa UInt8 && !(valtype in (0x78, 0x77))) &&
            throw(ArgumentError("a field's storage type is a value type or a packed i8/i16, not the raw byte $(repr(valtype))"))
        return new(valtype, mutable_)
    end
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:1338 FieldType)
FieldType(valtype::WasmValType)::FieldType = FieldType(valtype, true)  # Default to mutable

"""
    StructType

A WasmGC struct type with named fields.
parity(pkg/wasm_builder/lib/src/ir/type.dart:1119 StructType)
"""
struct StructType
    fields::Vector{FieldType}
    supertype_idx::Union{Nothing, UInt32}  # supertype index for subtyping (nothing = no supertype)
end

# Backward-compatible constructor (no supertype)
# parity(pkg/wasm_builder/lib/src/ir/type.dart:1119 StructType)
StructType(fields::Vector{FieldType})::StructType = StructType(fields, nothing)

"""
    ArrayType

A WasmGC array type with element type.
parity(pkg/wasm_builder/lib/src/ir/type.dart:1229 ArrayType)
"""
struct ArrayType
    elem::FieldType  # Element type with mutability
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:1229 ArrayType)
ArrayType(valtype::WasmValType)::ArrayType = ArrayType(FieldType(valtype, true))

"""
    CompositeType

Union of all composite types in WasmGC.
parity(pkg/wasm_builder/lib/src/ir/type.dart:708 DefType)
"""
const CompositeType = Union{FuncType, StructType, ArrayType}

# ============================================================================
# JS Interop Types
# ============================================================================

"""
    JSValue

A Julia type representing a JavaScript value held as an externref.
Used for DOM elements, JS objects, and other JS values.

This is a primitive type to prevent Julia from optimizing it away.
parity(sdk/lib/_wasm/wasm_types.dart:59 WasmExternRef)
"""
primitive type JSValue 64 end

# ============================================================================
# WasmGlobal - Handle for Wasm Global Variables
# ============================================================================

"""
    WasmGlobal{T, IDX}

A handle to a WebAssembly global variable at index `IDX`. When compiled to Wasm:
- `global[]` (getindex) → `global.get IDX`
- `global[] = x` (setindex!) → `global.set IDX, x`

The index is a type parameter so it's known at compile time, which is required
because Wasm's `global.get` and `global.set` instructions take immediate indices.

This is a general-purpose abstraction for any Julia code that needs to
interact with Wasm global variables. Use cases include:
- Stateful applications
- Game engines
- Reactive frameworks
- Any code needing mutable Wasm state

# Type Parameters
- `T`: The type of value stored in the global (Int32, Float64, etc.)
- `IDX`: The Wasm global index (0-based), must be an Int literal

# Example
```julia
# Define types for specific globals (index is compile-time constant)
const Counter = WasmGlobal{Int32, 0}   # Global index 0
const Flag = WasmGlobal{Int32, 1}      # Global index 1

# Functions that use globals - index is known from the type
function increment(g::Counter)::Int32
    g[] = g[] + Int32(1)
    return g[]
end

function toggle(g::Flag)::Int32
    g[] = g[] == Int32(0) ? Int32(1) : Int32(0)
    return g[]
end

# Create instances (value is for Julia-side testing)
counter = Counter(0)
flag = Flag(1)

# Compile to Wasm - global index extracted from type
wasm_bytes = compile(increment, (Counter,))
```
parity(quarantine: Julia has no declaration of a wasm global, so a host-shared global's index rides in the argument type WasmGlobal{T,IDX} to give global.get/global.set their immediate)
"""
mutable struct WasmGlobal{T, IDX}
    value::T
end

# Constructor with zero initial value
# parity(quarantine: WasmGlobal API — Julia has no declaration of a wasm global, so a host-shared global's index rides in the argument type WasmGlobal{T,IDX} to give global.get/global.set their immediate)
function WasmGlobal{T, IDX}()::WasmGlobal{T, IDX} where {T, IDX}
    return WasmGlobal{T, IDX}(zero(T))
end

# Get the global index from the type
# parity(quarantine: WasmGlobal API — Julia has no declaration of a wasm global, so a host-shared global's index rides in the argument type WasmGlobal{T,IDX} to give global.get/global.set their immediate)
function global_index(::Type{WasmGlobal{T, IDX}})::Int where {T, IDX}
    return IDX
end
# parity(quarantine: WasmGlobal API — Julia has no declaration of a wasm global, so a host-shared global's index rides in the argument type WasmGlobal{T,IDX} to give global.get/global.set their immediate)
function global_index(g::WasmGlobal{T, IDX})::Int where {T, IDX}
    return IDX
end

# Get the element type
# parity(quarantine: WasmGlobal API — Julia has no declaration of a wasm global, so a host-shared global's index rides in the argument type WasmGlobal{T,IDX} to give global.get/global.set their immediate)
function global_eltype(::Type{WasmGlobal{T, IDX}})::Type where {T, IDX}
    return T
end

# Accessor methods - work in Julia (for testing) and compile to Wasm global ops
# parity(quarantine: WasmGlobal API — Julia has no declaration of a wasm global, so a host-shared global's index rides in the argument type WasmGlobal{T,IDX} to give global.get/global.set their immediate)
function Base.getindex(g::WasmGlobal{T, IDX})::T where {T, IDX}
    return g.value
end

# parity(quarantine: WasmGlobal API — Julia has no declaration of a wasm global, so a host-shared global's index rides in the argument type WasmGlobal{T,IDX} to give global.get/global.set their immediate)
function Base.setindex!(g::WasmGlobal{T, IDX}, v::T)::T where {T, IDX}
    g.value = v
    return v
end
