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
`Core.SimpleVector`'s elements). No Julia value has either type: the wasm array is the value, and
Julia never holds it, so each is a struct of one field of type `Union{}`, uninhabited.

precedent(dart: dart:_wasm's WasmArray and ImmutableWasmArray; rust: `[T]`, a type only behind a
reference). Julia's differs: its runtime has no wasm array, so the type names the representation a
field takes and no value is made of it.
"""
@quarantine "dart:_wasm's WasmArray is a class of dart's runtime; Julia's runtime has no wasm array, so a field's type names it" Core.Union struct WasmArray{T}
    _never::Union{}
    WasmArray{T}(args...) where {T} = reject!(Internal("src/julia/wasm_array.jl: WasmArray has no Julia value; a field of its type holds the wasm array itself"), "WasmArray")
end
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
