include("test/utils.jl")
using WasmTarget

# Test functions with meaningful names
function calculate_sum(x::Int32)::Int32
    return x + Int32(10)
end

function validate_input(x::Int32)::Int32
    if x < Int32(0)
        error("negative input")
    end
    return x
end

function process_data(x::Int32)::Int32
    try
        y = validate_input(x)
        return calculate_sum(y)
    catch
        return Int32(-1)
    end
    return Int32(0)
end

println("=== Native Ground Truth ===")
println("process_data(5) = ", process_data(Int32(5)))
println("process_data(-3) = ", process_data(Int32(-3)))

# Compile multi-function module
bytes = WasmTarget.compile_multi([
    (calculate_sum, (Int32,)),
    (validate_input, (Int32,)),
    (process_data, (Int32,))
])

write("test_stacktrace2.wasm", bytes)
run(`wasm-tools validate test_stacktrace2.wasm`)
println("wasm-tools validate: PASS")

# Verify name section contains function names
wat = read(`wasm-tools print test_stacktrace2.wasm`, String)
println("\n=== Acceptance Criterion 1: Stack traces include Wasm function names ===")
for name in ["calculate_sum", "validate_input", "process_data"]
    found = contains(wat, "\$$name")
    println("  Name '\$$name' in WAT: $found")
end

# Also check that import has a name
println("  Import 'Math.pow' named: ", contains(wat, "\$Math.pow"))

# Verify execution correctness
r1 = run_wasm(bytes, "process_data", Int32(5))
println("\nWasm: process_data(5) = $r1 -- $(r1 == 15 ? "CORRECT" : "MISMATCH")")
r2 = run_wasm(bytes, "process_data", Int32(-3))
println("Wasm: process_data(-3) = $r2 -- $(r2 == -1 ? "CORRECT" : "MISMATCH")")

# Test that stack trace capture works with JS import
println("\n=== Acceptance Criterion 2: Trace attached to exception display ===")
dir = mktempdir()
wasm_path = joinpath(dir, "module.wasm")
js_path = joinpath(dir, "trace_test.mjs")
write(wasm_path, bytes)

js_code = """
import fs from 'fs';
const bytes = fs.readFileSync('$(escape_string(wasm_path))');
const importObject = { Math: { pow: Math.pow } };
const wasmModule = await WebAssembly.instantiate(bytes, importObject);

// Call function that internally catches - verify it works
const r1 = wasmModule.instance.exports.process_data(5);
console.log("process_data(5) =", r1);

// Call function that throws directly - verify stack trace has wasm function name
try {
    wasmModule.instance.exports.validate_input(-1);
    console.log("ERROR: should have thrown");
} catch (e) {
    // Wasm exceptions are WebAssembly.Exception objects
    // Check if stack property exists (V8/Node behavior varies)
    const hasStack = e.stack !== undefined && e.stack !== null;
    const stackStr = hasStack ? e.stack : "";
    // In V8, wasm function names appear in stack traces when name section exists
    const hasWasmInStack = stackStr.includes("wasm") || stackStr.includes("validate");
    console.log("Exception caught: type=" + (e instanceof WebAssembly.Exception ? "WebAssembly.Exception" : typeof e));
    console.log("Has stack:", hasStack);
    if (hasStack) {
        console.log("Stack snippet:", stackStr.substring(0, 300));
        console.log("Stack includes wasm reference:", hasWasmInStack);
    }
}

// Also test: create a JS Error at the wasm boundary to get a trace
try {
    wasmModule.instance.exports.validate_input(-1);
} catch (e) {
    const trace = new Error("Caught wasm exception");
    console.log("\\nJS Error.stack at catch site:");
    console.log(trace.stack.substring(0, 300));
}
"""
open(js_path, "w") do io
    print(io, js_code)
end
result = read(`node $js_path`, String)
println(result)
