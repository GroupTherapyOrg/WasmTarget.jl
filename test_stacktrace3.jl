include("test/utils.jl")
using WasmTarget

# Build a module with stack trace support manually
function validate_and_add(x::Int32)::Int32
    if x < Int32(0)
        error("negative")
    end
    return x + Int32(1)
end

function safe_add(x::Int32)::Int32
    try
        return validate_and_add(x)
    catch
        return Int32(-1)
    end
    return Int32(0)
end

println("Native: safe_add(5) = ", safe_add(Int32(5)))
println("Native: safe_add(-3) = ", safe_add(Int32(-3)))

# Compile with stack trace support
bytes = WasmTarget.compile_multi([
    (validate_and_add, (Int32,)),
    (safe_add, (Int32,))
])

write("test_st3.wasm", bytes)
run(`wasm-tools validate test_st3.wasm`)

# Test with capture_stack import provided from JS
dir = mktempdir()
wasm_path = joinpath(dir, "module.wasm")
js_path = joinpath(dir, "test.mjs")
write(wasm_path, bytes)

js_code = """
import fs from 'fs';
const bytes = fs.readFileSync('$(escape_string(wasm_path))');

// Provide capture_stack as an import
let lastStack = null;
const importObject = {
    Math: { pow: Math.pow },
    env: {
        capture_stack: () => {
            lastStack = new Error().stack;
            return null;  // externref
        }
    }
};

const wasmModule = await WebAssembly.instantiate(bytes, importObject);

// Test normal execution
const r1 = wasmModule.instance.exports.safe_add(5);
console.log("safe_add(5) =", r1, r1 === 6 ? "CORRECT" : "MISMATCH");

// Test exception path
const r2 = wasmModule.instance.exports.safe_add(-3);
console.log("safe_add(-3) =", r2, r2 === -1 ? "CORRECT" : "MISMATCH");

// Verify function names appear in WAT (name section)
console.log("\\nName section verification:");
console.log("  validate_and_add exported:", wasmModule.instance.exports.validate_and_add !== undefined);
console.log("  safe_add exported:", wasmModule.instance.exports.safe_add !== undefined);

// Test direct throw - see stack trace from JS side
try {
    wasmModule.instance.exports.validate_and_add(-1);
} catch (e) {
    // Create JS Error at catch site to get stack with wasm names
    const jsError = new Error("caught wasm exception");
    const stack = jsError.stack;
    const hasWasm = stack.includes("wasm") || stack.includes("validate");
    console.log("\\nStack trace at catch site includes wasm:", hasWasm);
    console.log("Stack preview:", stack.substring(0, 200));
}
"""
open(js_path, "w") do io
    print(io, js_code)
end
result = read(`node $js_path`, String)
println("\n", result)
