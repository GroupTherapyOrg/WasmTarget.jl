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

"""
A host string of the ASCII bytes `char_codes[start:start+length]` (dart's `@pragma("wasm:import",
"dart.stringFromAsciiBytes") external WasmExternRef stringFromAsciiBytes(WasmArray<WasmI8> charCodes,
WasmI32 start, WasmI32 length)`), the string the embedder made of them. A foreign call of the embedder's
function, never inlined, as stack_trace_get_current; the array crosses as a reference.
"""
@parity "sdk/lib/_internal/wasm/standalone/embedder.dart:71 stringFromAsciiBytes" @noinline string_from_ascii_bytes(char_codes::WasmArray{WasmI8}, start::Int32, length::Int32)::WasmExternRef =
    ccall((:stringFromAsciiBytes, "dart"), WasmExternRef, (Any, Int32, Int32), char_codes, start, length)

"""
The embedder's print of a host string (dart's `@pragma("wasm:import", "dart.print") external WasmVoid
print(WasmExternRef? line)`): the line to the host's console, where a standalone module's text goes. A method of
Base's `print` on WasmTarget's own host reference type, since the module Runtime's `print` is Base's.
"""
@parity "sdk/lib/_internal/wasm/standalone/embedder.dart:437 print" @noinline Base.print(line::WasmExternRef)::Nothing =
    ccall((:print, "dart"), Nothing, (WasmExternRef,), line)
