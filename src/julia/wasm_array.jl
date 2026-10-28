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
