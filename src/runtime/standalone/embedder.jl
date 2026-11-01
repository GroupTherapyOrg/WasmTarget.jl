# parity(sdk/lib/_internal/wasm/standalone/embedder.dart): dart's standalone embedder library at the pin,
# the imports a module compiled without JavaScript takes from its embedder's `dart` module, ported as
# Julia methods of the module Runtime (src/julia/parity.jl RUNTIME_FILES), each a foreign call of the
# embedder's function, which the code generator imports (src/julia/runtime/rtutils.jl
# nir_foreign_import, the embedder's module a host module).

"""
The host's stack trace at the call (dart's `@pragma("wasm:import", "dart.stackTraceGetCurrent")
external WasmExternRef stackTraceGetCurrent()`), a host reference the embedder made, which
`stackTraceToString` renders. A foreign call of the embedder's function, never inlined, so its call
stays the import's call, as dart's `external` member's does.
"""
@parity "sdk/lib/_internal/wasm/standalone/embedder.dart:238 stackTraceGetCurrent" @noinline stack_trace_get_current()::WasmExternRef =
    ccall((:stackTraceGetCurrent, "dart"), WasmExternRef, ())
