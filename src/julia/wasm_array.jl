# dart:_wasm's array literal (dev/MARCH.md 1.C): dart2wasm builds its runtime type tables as constants
# of dart:_wasm's `WasmArray<T>` and `ImmutableWasmArray<T>` classes (constants.dart makeArrayOf,
# makeTypeArray), which Kernel canonicalizes structurally. Julia's runtime has no such class, and a
# `Memory` is compared by identity, so the literal is a value of its own, immutable, compared by
# Julia's egal field by field: two literals of the same element type, mutability and entries are one
# constant, as two equal Kernel InstanceConstants are.

"""
    WasmArrayLiteral(element_type, mutable, entries)

The value of a constant `WasmArray<element_type>` (`mutable`) or `ImmutableWasmArray<element_type>`:
its `entries`, each a constant (the NIR's literal, `NirConst`), in order. A constant holding it is
the NIR's literal of it, `NirConst(Core.Const(WasmArrayLiteral(...)))`, which ConstantCreator
recognizes as dart's wasm array class.
"""
@quarantine "dart2wasm's runtime type tables are constants of dart:_wasm's WasmArray, a class Julia's runtime has no counterpart of" Core.Tuple struct WasmArrayLiteral
    element_type::Type
    mutable::Bool
    entries::Tuple{Vararg{NirConst}}
end

"""
    WasmArray{T}
    ImmutableWasmArray{T}

dart:_wasm's array classes as types (sdk/lib/_wasm/wasm_types.dart:731 `class WasmArray<T>` and
:814 `class ImmutableWasmArray<T>`): the type of a field that holds a wasm array of `T`, which
dart's translateStorageType (translator.dart:1085, :1094) translates to a reference to
`arrayTypeForDartType(T, mutable: …)`. dart's runtime type objects hold their type arguments in
one (sdk/lib/_internal/wasm/common/type.dart:277, `final WasmArray<_Type> typeArguments;`), and a
Julia object whose data lies outside its fields does too (src/julia/classes.jl, a
`Core.SimpleVector`'s elements). A mutable one is also a value Julia code holds, as dart's runtime
does (js_string.dart's `WasmArray<WasmI16>(length)`, written element by element and passed to a host
import): Julia's inference must see it flow through a body, so `WasmArray{T}` is inhabited, a
primitive type of a pointer's width whose bits Julia never reads, made and used only through
dart:_wasm's operations below (wasm_array_new, wasm_array_write!, wasm_array_length), which the
code generator lowers to wasm's array instructions. No Julia value has the immutable one, a struct of
one field of type `Union{}`, uninhabited.

precedent(dart: dart:_wasm's WasmArray and ImmutableWasmArray; rust: `[T]`, a type only behind a
reference). Julia's differs: its runtime has no wasm array, so the type names the representation and
no Julia operation reads it.
"""
@quarantine "dart:_wasm's WasmArray is a class of dart's runtime; Julia's runtime has no wasm array, so a value's type names it" Core.Any primitive type WasmArray{T} <: Any 64 end
@quarantine "dart:_wasm's ImmutableWasmArray is a class of dart's runtime; Julia's runtime has no wasm array, so a field's type names it" Core.Union struct ImmutableWasmArray{T}
    _never::Union{}
    ImmutableWasmArray{T}(args...) where {T} = reject!(Internal("src/julia/wasm_array.jl: ImmutableWasmArray has no Julia value; a field of its type holds the wasm array itself"), "ImmutableWasmArray")
end

"""
    WasmI8

dart:_wasm's 8-bit wasm integer (sdk/lib/_wasm/wasm_types.dart, `class WasmI8`), the element type of a
packed i8 wasm array: a wasm type, never boxed, so translateStorageType gives its builtin type, the
packed i8, even where it boxes a Julia primitive class (dart's `!boxClasses.contains(cls)`). A
String's code units are a `WasmArray` of it (src/julia/classes.jl `_string_instance_fields`). No
Julia value has the type: a struct of one field of type `Union{}`, uninhabited.

precedent(dart: dart:_wasm's WasmI8, a storage type of packed arrays only; rust: `u8` in a `[u8]`).
Julia's differs: its UInt8 is a class of its own, boxed where it flows into `Any`, so the packed
storage type is named apart from it.
"""
@quarantine "dart:_wasm's WasmI8 is a storage type of dart's runtime; Julia's UInt8 is a boxable class, so a field's element type names the packed i8" Core.Union struct WasmI8
    _never::Union{}
    WasmI8(args...) = reject!(Internal("src/julia/wasm_array.jl: WasmI8 has no Julia value; it names a packed array's element type"), "WasmI8")
end

"""
    WasmI32

dart:_wasm's 32-bit wasm integer (sdk/lib/_wasm/wasm_types.dart, `class WasmI32`), the element type of a wasm array
of the i32s, stored unboxed: a wasm type, never boxed, so translateStorageType gives its builtin type,
the i32, even where it boxes a Julia primitive class. A `Memory` of Int32 and UInt32 holds its elements in a
`WasmArray` of it (src/julia/classes.jl `_memory_element_storage`). No Julia value has the type.

precedent(dart: dart:_wasm's WasmI32, a storage type of wasm arrays; rust: a primitive in a slice).
Julia's differs: its Int32 and UInt32 are classes of their own, boxed where they flow into `Any`, so the unboxed
storage type is named apart from them.
"""
@quarantine "dart:_wasm's WasmI32 is a storage type of dart's runtime; Julia's Int32 and UInt32 are boxable classes, so an array's element type names the unboxed i32" Core.Union struct WasmI32
    _never::Union{}
    WasmI32(args...) = reject!(Internal("src/julia/wasm_array.jl: WasmI32 has no Julia value; it names an array's element type"), "WasmI32")
end

"""
    WasmI64

dart:_wasm's 64-bit wasm integer (sdk/lib/_wasm/wasm_types.dart, `class WasmI64`), the element type of a wasm array
of the i64s, stored unboxed: a wasm type, never boxed, so translateStorageType gives its builtin type,
the i64, even where it boxes a Julia primitive class. A `Memory` of Int64 and UInt64 holds its elements in a
`WasmArray` of it (src/julia/classes.jl `_memory_element_storage`). No Julia value has the type.

precedent(dart: dart:_wasm's WasmI64, a storage type of wasm arrays; rust: a primitive in a slice).
Julia's differs: its Int64 and UInt64 are classes of their own, boxed where they flow into `Any`, so the unboxed
storage type is named apart from them.
"""
@quarantine "dart:_wasm's WasmI64 is a storage type of dart's runtime; Julia's Int64 and UInt64 are boxable classes, so an array's element type names the unboxed i64" Core.Union struct WasmI64
    _never::Union{}
    WasmI64(args...) = reject!(Internal("src/julia/wasm_array.jl: WasmI64 has no Julia value; it names an array's element type"), "WasmI64")
end

"""
    WasmF32

dart:_wasm's 32-bit wasm float (sdk/lib/_wasm/wasm_types.dart, `class WasmF32`), the element type of a wasm array
of the f32s, stored unboxed: a wasm type, never boxed, so translateStorageType gives its builtin type,
the f32, even where it boxes a Julia primitive class. A `Memory` of Float32 holds its elements in a
`WasmArray` of it (src/julia/classes.jl `_memory_element_storage`). No Julia value has the type.

precedent(dart: dart:_wasm's WasmF32, a storage type of wasm arrays; rust: a primitive in a slice).
Julia's differs: its Float32 are classes of their own, boxed where they flow into `Any`, so the unboxed
storage type is named apart from them.
"""
@quarantine "dart:_wasm's WasmF32 is a storage type of dart's runtime; Julia's Float32 are boxable classes, so an array's element type names the unboxed f32" Core.Union struct WasmF32
    _never::Union{}
    WasmF32(args...) = reject!(Internal("src/julia/wasm_array.jl: WasmF32 has no Julia value; it names an array's element type"), "WasmF32")
end

"""
    WasmF64

dart:_wasm's 64-bit wasm float (sdk/lib/_wasm/wasm_types.dart, `class WasmF64`), the element type of a wasm array
of the f64s, stored unboxed: a wasm type, never boxed, so translateStorageType gives its builtin type,
the f64, even where it boxes a Julia primitive class. A `Memory` of Float64 holds its elements in a
`WasmArray` of it (src/julia/classes.jl `_memory_element_storage`). No Julia value has the type.

precedent(dart: dart:_wasm's WasmF64, a storage type of wasm arrays; rust: a primitive in a slice).
Julia's differs: its Float64 are classes of their own, boxed where they flow into `Any`, so the unboxed
storage type is named apart from them.
"""
@quarantine "dart:_wasm's WasmF64 is a storage type of dart's runtime; Julia's Float64 are boxable classes, so an array's element type names the unboxed f64" Core.Union struct WasmF64
    _never::Union{}
    WasmF64(args...) = reject!(Internal("src/julia/wasm_array.jl: WasmF64 has no Julia value; it names an array's element type"), "WasmF64")
end

"""
    WasmI16

dart:_wasm's 16-bit wasm integer (sdk/lib/_wasm/wasm_types.dart, `class WasmI16`), the element type of
a packed i16 wasm array, a JS string's UTF-16 code units (js_string.dart's `WasmArray<WasmI16>`): a
wasm type, never boxed, so translateStorageType gives its builtin type, the packed i16. An element is
written as a `UInt16`. No Julia value has the type: a struct of one field of type `Union{}`,
uninhabited.

precedent(dart: dart:_wasm's WasmI16, a storage type of packed arrays only; rust: `u16` in a
`[u16]`). Julia's differs: its UInt16 is a class of its own, boxed where it flows into `Any`, so the
packed storage type is named apart from it.
"""
@quarantine "dart:_wasm's WasmI16 (sdk/lib/_wasm/wasm_types.dart:151 WasmI16) is a storage type of dart's runtime; Julia's UInt16 is a boxable class, so an array's element type names the packed i16" Core.Union struct WasmI16
    _never::Union{}
    WasmI16(args...) = reject!(Internal("src/julia/wasm_array.jl: WasmI16 has no Julia value; it names a packed array's element type"), "WasmI16")
end

# dart:_wasm's storage classes this file defines, each never boxed (translateStorageType)
@quarantine "dart:_wasm's storage classes are the wasm types translateStorageType never boxes" Core.Tuple const WASM_STORAGE_TYPES::Tuple{Vararg{DataType}} = (WasmI8, WasmI16, WasmI32, WasmI64, WasmF32, WasmF64)

# a dart:_wasm operation's native body: no wasm array exists natively, so the body raises, loud, and
# its value is hidden from inference (compilerbarrier) so Julia never folds a wasm array's operation;
# inlined, so it lies in the operation's body, which the closed world never collects
@quarantine "dart declares a wasm array operation external, its body the compiler's (sdk/lib/_wasm/wasm_types.dart:737 WasmArray); no wasm array exists natively, so its native body raises, its value hidden from Julia's inference" Base.compilerbarrier @inline function _wasm_only(::Type{R})::R where {R}
    local r = Base.compilerbarrier(:type, nothing)
    r === nothing && error("src/julia/wasm_array.jl: a wasm array operation, run natively; only the compiled module holds a wasm array")
    return r::R
end

"""
    wasm_array_new(WasmArray{T}, n) -> WasmArray{T}

A new mutable wasm array of `n` elements of `T`, each the default: dart's `WasmArray<T>(length)`
constructor (sdk/lib/_wasm/wasm_types.dart), `array.new_default`. Never inlined, so the code
generator meets the call and lowers it (src/intrinsics.jl).
"""
@quarantine "dart:_wasm's WasmArray constructor (sdk/lib/_wasm/wasm_types.dart:737 WasmArray) is one wasm instruction; no wasm array exists natively" Core.Int @noinline wasm_array_new(::Type{WasmArray{T}}, n::Int) where {T} =
    _wasm_only(WasmArray{T})

"""
    wasm_array_write!(a, i, v) -> Nothing

Writes `v` at offset `i` (from 0) of `a`, unchecked: dart's `WasmArray<T>.write`, `array.set`, a packed
element truncated as wasm's array.set truncates.
"""
@quarantine "dart:_wasm's WasmArray write (sdk/lib/_wasm/wasm_types.dart:748 operator) is one wasm instruction; no wasm array exists natively" Core.Int @noinline wasm_array_write!(a::WasmArray{T}, i::Int, v::Union{UInt16,Int32,Int64,Float64}) where {T} =
    (_wasm_only(Int); nothing)

"""
    wasm_array_length(a) -> Int

The number of elements of `a`: dart's `WasmArrayRef.length`, `array.len`.
"""
@quarantine "dart:_wasm's WasmArray length (sdk/lib/_wasm/wasm_types.dart:142 length) is one wasm instruction; no wasm array exists natively" Core.Int @noinline wasm_array_length(a::WasmArray) =
    _wasm_only(Int)

"""
    WasmExternRef

dart:_wasm's host reference (sdk/lib/_wasm/wasm_types.dart:59, `class WasmExternRef extends
_WasmBase`), wasm's `externref`: a value the host made and the module only holds and passes back, the
type of a host import's argument or result (src/julia/runtime/rtutils.jl nir_foreign_import), never
boxed, nullable as `Union{Nothing,WasmExternRef}` (dart's `WasmExternRef?`). Julia's inference must
see its values flow through a body, so the type is inhabited, a primitive type of a pointer's width,
whose bits Julia never reads: only a host import makes one.

precedent(dart: dart:_wasm's WasmExternRef; rust: wasm-bindgen's `JsValue`, an index into the host's
table). Julia's differs: its runtime has no host reference, so the type names the representation and
no Julia operation reads it.
"""
@quarantine "dart:_wasm's WasmExternRef (sdk/lib/_wasm/wasm_types.dart:59 WasmExternRef) is a class of dart's runtime; Julia's runtime has no host reference, so a value's type names it" Core.Any primitive type WasmExternRef <: Any 64 end

# ---- a String's data, read and written as dart:_wasm reads and writes a WasmArray --------------------
# A String is its class's struct, the header and then `_data`, a wasm array of its UTF-8 code units
# (src/julia/classes.jl _string_instance_fields). dart's string patches read and write their data
# through dart:_wasm's WasmArray operations (sdk/lib/_wasm/wasm_types.dart: `length`,
# `readUnsigned`, the `WasmArray<WasmI8>(length)` constructor, `copy`), each one wasm instruction. These
# are those operations on a String's data: the code generator lowers each call to its instruction, so
# each stays a call (`@noinline`, as dart's are `external` members the intrinsifier meets at the call), and
# natively each computes Julia's own answer on a Julia String, so an overlay written with them answers
# as native Julia does wherever Julia evaluates it at compile time. Offsets count from 0, as a wasm
# array's do.

"""
    wasm_string_length(s) -> Int

The number of code units in `s`'s data: dart's `WasmArray.length`, `struct.get _data; array.len`
(zero-extended). Natively Julia's `Core.sizeof(s)`, a String's byte length (jl_string_len).
"""
@quarantine "a String's byte length is its wasm data array's length, Julia's Core.sizeof natively" Core.sizeof @noinline wasm_string_length(s::String)::Int = Core.sizeof(s)

"""
    wasm_string_codeunit(s, i) -> UInt8

The code unit at offset `i` (from 0) of `s`'s data, unchecked: dart's `WasmArray<WasmI8>.readUnsigned`,
`struct.get _data; array.get_u`. Natively Julia's byte of the String (jl_string_data), its `i + 1`th.
"""
@quarantine "a String's byte at an offset is its wasm data array's element, Julia's byte natively" Base.unsafe_load @noinline function wasm_string_codeunit(s::String, i::Int)::UInt8
    return GC.@preserve s unsafe_load(pointer(s), i + 1)
end

"""
    wasm_string_alloc(n) -> String

A new String of `n` code units, each 0, to be filled before it is read: dart's
`WasmArray<WasmI8>(length)`, `array.new_default` wrapped in the String's struct. Natively Julia's
jl_alloc_string, called as `Base._string_n` calls it, a fresh String whose bytes its caller writes;
never through `_string_n` itself, which src/patch/string.jl's overlay maps back here, so the closed
world would infer the pair as a loop that never returns.
"""
@quarantine "a new String of n bytes is a new wasm data array in its struct, Julia's jl_alloc_string natively" Base.Csize_t @noinline wasm_string_alloc(n::Int)::String =
    ccall(:jl_alloc_string, Ref{String}, (Csize_t,), n)

"""
    wasm_string_copy!(dst, dst_offset, src, src_offset, n) -> Nothing

Copies `n` code units of `src`'s data from `src_offset` into `dst`'s from `dst_offset`, both from 0, a
fresh String's (wasm_string_alloc): dart's `WasmArray.copy`, `array.copy`. Natively Julia's
`unsafe_copyto!` of the bytes, as Base's `_string` fills a fresh String.
"""
@quarantine "copying bytes into a fresh String is a wasm array.copy, Julia's unsafe_copyto! natively" Base.unsafe_copyto! @noinline function wasm_string_copy!(dst::String, dst_offset::Int, src::String, src_offset::Int, n::Int)::Nothing
    GC.@preserve dst src unsafe_copyto!(pointer(dst) + dst_offset, pointer(src) + src_offset, n)
    return nothing
end

"""
    wasm_memory_copy!(dest, src, n) -> Nothing

Copies `n` elements of `src`'s memory from its reference's offset into `dest`'s memory from its own,
unchecked, the two ranges possibly overlapping: Julia's runtime copy of a memory's elements
(genericmemory.c jl_genericmemory_copyto, which copies forwards or backwards as the ranges overlap),
over WasmTarget's layout one `array.copy` of the memories' data arrays (dart's `WasmArray.copy`,
memmove's semantics) and, for elements admitting nothing, one of their set flags. Never inlined, so the
code generator meets the call and lowers it (src/intrinsics.jl); natively Base's copy.
"""
@quarantine "julia/src/genericmemory.c:223 jl_genericmemory_copyto copies a memory's elements, overlapping ranges included; WasmGC copies the data arrays (array.copy)" Base.unsafe_copyto! @noinline function wasm_memory_copy!(dest::MemoryRef{T}, src::MemoryRef{T}, n::Int)::Nothing where {T}
    unsafe_copyto!(dest, src, n)
    return nothing
end
