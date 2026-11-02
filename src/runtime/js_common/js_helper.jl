# parity(sdk/lib/_internal/wasm/js_common/js_helper.dart): dart:_js_helper's helpers at the pin, the
# runtime's JS interop, each port a Julia method of the module Runtime (src/julia/parity.jl RUNTIME_FILES).

"""
Whether two host references are the same JS value (dart's `bool areEqualInJS(WasmExternRef? l,
WasmExternRef? r) => JS<bool>("(l, r) => l === r", l, r)`): JS's strict equality, the inline JS a
foreign call to the interop module hands its host (src/julia/runtime/rtutils.jl JS_INTEROP_LIBRARY),
its result the JS boolean as an i32. It is how a field holding a host reference is to be compared by
jl_egal (no eqref holds an externref), as dart compares two JS values; jl_egal's arm for such a field
does not call it yet (src/intrinsics.jl, its egal arm, wt3-memory's). dart's `WasmExternRef?` crosses as the
nullable externref (nir_foreign_param_type), Julia's `nothing` the null.
"""
@parity "sdk/lib/_internal/wasm/js_common/js_helper.dart:151 areEqualInJS" are_equal_in_js(l::WasmExternRef, r::WasmExternRef)::Bool =
    ccall(("(l, r) => l === r", "dart2wasm"), Bool, (WasmExternRef, WasmExternRef), l, r)
