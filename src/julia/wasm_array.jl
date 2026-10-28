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
