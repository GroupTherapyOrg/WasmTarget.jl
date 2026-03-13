include("test/utils.jl")
using WasmTarget

function hello_println()::Nothing
    println("hello")
    return nothing
end

function multi_println()::Nothing
    println("hello")
    println("world")
    return nothing
end

function print_no_newline()::Nothing
    print("no newline")
    return nothing
end

# Compile each
for (f, name) in [(hello_println, "hello_println"),
                   (multi_println, "multi_println"),
                   (print_no_newline, "print_no_newline")]
    println("=== Compiling $name ===")
    bytes = WasmTarget.compile(f, ())
    write("test_$(name).wasm", bytes)
    run(`wasm-tools validate test_$(name).wasm`)
    println("  Compiled: $(length(bytes)) bytes, validates OK")

    # Run with V8 builtins for text-decoder
    dir = mktempdir()
    wasm_path = joinpath(dir, "module.wasm")
    js_path = joinpath(dir, "test.mjs")
    write(wasm_path, bytes)

    js_code = """
import fs from 'fs';
const bytes = fs.readFileSync('$(escape_string(wasm_path))');
const output = [];
const importObject = {
    Math: { pow: Math.pow },
    io: {
        write_string: (s) => { output.push(String(s)); },
        write_int: (n) => { output.push(String(n)); },
        write_float: (f) => { output.push(String(f)); },
        write_bool: (b) => { output.push(b ? "true" : "false"); },
        write_newline: () => { output.push("\\n"); }
    }
};
try {
    const wasmModule = await WebAssembly.instantiate(bytes, importObject,
        { builtins: ["js-string", "text-decoder", "text-encoder"] });
    wasmModule.instance.exports.$(name)();
    console.log(JSON.stringify(output.join("")));
} catch (e) {
    console.error("Error:", e.message);
    // Fallback: try without builtins but with manual polyfill
    try {
        importObject['wasm:text-decoder'] = {
            decodeStringFromUTF8Array: (arr, start, end_) => {
                // WasmGC arrays expose .length and indexing via arr[i]
                const bytes = [];
                for (let i = start; i < end_; i++) bytes.push(arr[i]);
                return new TextDecoder().decode(new Uint8Array(bytes));
            }
        };
        const wasmModule = await WebAssembly.instantiate(bytes, importObject);
        wasmModule.instance.exports.$(name)();
        console.log(JSON.stringify(output.join("")));
    } catch (e2) {
        console.error("Fallback error:", e2.message);
    }
}
"""
    open(js_path, "w") do io_file
        print(io_file, js_code)
    end
    result = strip(read(`node --experimental-wasm-imported-strings-utf8 $js_path`, String))
    println("  Output: $result")
end
