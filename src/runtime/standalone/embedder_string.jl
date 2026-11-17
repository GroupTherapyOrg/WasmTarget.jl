# parity(sdk/lib/_internal/wasm/standalone/embedder_string.dart): dart's standalone string library at the pin,
# the embedder's string a dart String is in a module without JavaScript, ported as Julia methods of the module
# Runtime (src/julia/parity.jl RUNTIME_FILES), as far as a Julia String needs it to reach the embedder.

"""
The embedder's string of the bytes of `source` from `start` (0-based) to `end_` (dart's `static EmbedderStringImpl
fromAsciiBytes(WasmArray<WasmI8> source, int start, int end)`: the embedder's stringFromAsciiBytes of them).
Reshaped as JSStringImpl_from_ascii_bytes is (src/runtime/js_common/js_string.jl): `source` is the String itself,
whose bytes are copied into an array of WasmI8 (a String's data array being no value Julia code holds), and the
host reference is answered, dart's `fromRefUnchecked` wrapper being no class of WasmTarget's. The bytes are read as
ASCII, as dart's fromAsciiBytes reads them.
"""
@parity "sdk/lib/_internal/wasm/standalone/embedder_string.dart:96 EmbedderStringImpl.fromAsciiBytes" function EmbedderStringImpl_from_ascii_bytes(source::String, start::Int, end_::Int)::WasmExternRef
    local n = end_ - start
    local bytes = wasm_array_new(WasmArray{WasmI8}, n)
    local i = 0
    while i < n
        wasm_array_write!(bytes, i, Int32(wasm_string_codeunit(source, start + i)))
        i += 1
    end
    return string_from_ascii_bytes(bytes, Int32(0), n % Int32)
end
