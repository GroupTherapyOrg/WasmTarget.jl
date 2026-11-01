# parity(sdk/lib/_internal/wasm/js_common/print_patch.dart): dart's JS print patch at the pin, its port
# a Julia method of the module Runtime (src/julia/parity.jl RUNTIME_FILES).

"""
Prints `line` on the JS host's console (dart's `@patch void printToConsole(String line) =>
JS<void>('s => printToConsole(s)', jsStringFromDartString(line).wrappedExternRef)`): the line made a
JS string, as jsStringFromDartString makes one (js_string.dart's JSStringImpl.fromAsciiBytes over a
Julia String's bytes, src/runtime/js_common/js_string.jl), handed to the inline JS
`s => printToConsole(s)`, the JS runtime's printToConsole (runtime_blob.dart). dart's JS<void> is a
foreign call to the interop module (src/julia/runtime/rtutils.jl JS_INTEROP_LIBRARY), its symbol the
JS code, which the runtime generator writes into the JS runtime's methods (generateJsMethods).
"""
@parity "sdk/lib/_internal/wasm/js_common/print_patch.dart:8 printToConsole" print_to_console(line::String)::Nothing =
    ccall(("s => printToConsole(s)", "dart2wasm"), Nothing, (WasmExternRef,), JSStringImpl_from_ascii_bytes(line, 0, ncodeunits(line)))
