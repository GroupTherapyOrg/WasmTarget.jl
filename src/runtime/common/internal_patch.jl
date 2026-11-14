# parity(sdk/lib/_internal/wasm/common/internal_patch.dart): dart:_internal's patch at the pin, its
# ports Julia methods of the module Runtime (src/julia/parity.jl RUNTIME_FILES).

"""
`v` as a value of `T`, unchecked (dart's `@pragma("wasm:intrinsic") external T unsafeCast<T>(Object?
v)`): the intrinsifier translates the operand at `T`'s wasm type, the conversion a cast with no test,
as dart lets the context convert it. The runtime's type code narrows by it after a test of the value's
class, as dart's type.dart does, holding no type test of its own (`isa`), which verifyTypeChecks would
check again. Natively the value itself, asserted.
"""
@parity "sdk/lib/_internal/wasm/common/internal_patch.dart:49 unsafeCast" @noinline unsafe_cast(::Type{T}, @nospecialize(v::Any)) where {T} = v::T
