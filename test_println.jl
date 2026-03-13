include("test/utils.jl")
using WasmTarget

# Test function with println
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

println("=== Native Ground Truth ===")
hello_println()
multi_println()
print_no_newline()
println()  # newline after print

# Compile
println("\n=== Compiling hello_println ===")
try
    bytes = WasmTarget.compile(hello_println, ())
    write("test_println.wasm", bytes)
    println("Compiled: $(length(bytes)) bytes")
    run(`wasm-tools validate test_println.wasm`)
    println("wasm-tools validate: PASS")

    # Run with IO imports
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
    'wasm:text-decoder': {
        decodeStringFromUTF8Array: (arr, start, end_) => {
            const decoder = new TextDecoder();
            const uint8 = new Uint8Array(arr.length);
            for (let i = start; i < end_; i++) uint8[i - start] = arr[i];
            return decoder.decode(uint8.slice(0, end_ - start));
        }
    },
    io: {
        write_string: (s) => { output.push(String(s)); },
        write_int: (n) => { output.push(String(n)); },
        write_float: (f) => { output.push(String(f)); },
        write_bool: (b) => { output.push(b ? "true" : "false"); },
        write_newline: () => { output.push("\\n"); }
    }
};
try {
    const wasmModule = await WebAssembly.instantiate(bytes, importObject);
    wasmModule.instance.exports.hello_println();
    console.log("Output:", JSON.stringify(output.join("")));
} catch (e) {
    console.error("Error:", e.message, e.stack);
}
"""
    open(js_path, "w") do io
        print(io, js_code)
    end
    result = read(`node $js_path`, String)
    println("Node.js result: ", result)
catch e
    println("ERROR: ", e)
    println(sprint(showerror, e, catch_backtrace()))
end
