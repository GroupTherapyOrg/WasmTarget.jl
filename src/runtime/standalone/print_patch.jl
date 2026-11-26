# parity(sdk/lib/_internal/wasm/standalone/print_patch.dart): dart's standalone print patch at the pin, its port a
# Julia method of the module Runtime (src/julia/parity.jl RUNTIME_FILES).

"""
Prints `line` on the standalone embedder's console (dart's `@patch void printToConsole(String line) =>
embedder.print(embedderStringFromDartString(line).wrappedExternRef)`): the line made the embedder's string, as
embedderStringFromDartString makes one (embedder_string.dart's EmbedderStringImpl.fromAsciiBytes over a Julia
String's bytes, as the JS patch's port makes its JS string, src/runtime/js_common/print_patch.jl), handed to the
embedder's print (embedder.dart:437, src/runtime/standalone/embedder.jl).

dart compiles one patch library per target, so its two `printToConsole`s never meet; WasmTarget loads both patches
into the one module Runtime, so the JS patch's port is `print_to_console` and this one takes dart's own spelling,
the naming rule's other admitted name for the symbol; KernelNodes.printToConsole picks one by the target.
"""
@parity "sdk/lib/_internal/wasm/standalone/print_patch.dart:9 printToConsole" printToConsole(line::String)::Nothing =
    print(EmbedderStringImpl_from_ascii_bytes(line, 0, ncodeunits(line)))
