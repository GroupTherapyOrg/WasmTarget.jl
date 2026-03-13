include("test/utils.jl")
using WasmTarget

# Function that throws - stack trace should show function name
function might_throw(x::Int32)::Int32
    if x < Int32(0)
        error("negative")
    end
    return x + Int32(1)
end

function catch_and_return(x::Int32)::Int32
    try
        return might_throw(x)
    catch
        return Int32(-1)
    end
    return Int32(0)
end

println("Native: catch_and_return(5) = ", catch_and_return(Int32(5)))
println("Native: catch_and_return(-3) = ", catch_and_return(Int32(-3)))

# Compile
bytes = WasmTarget.compile_multi([
    (might_throw, (Int32,)),
    (catch_and_return, (Int32,))
])

write("test_stacktrace.wasm", bytes)
run(`wasm-tools validate test_stacktrace.wasm`)
println("wasm-tools validate: PASS")

# Check that names are present
wat = read(`wasm-tools print test_stacktrace.wasm`, String)
has_might_throw = contains(wat, "\$might_throw")
has_catch_return = contains(wat, "\$catch_and_return")
println("Name section has 'might_throw': $has_might_throw")
println("Name section has 'catch_and_return': $has_catch_return")

# Test execution
r1 = run_wasm(bytes, "catch_and_return", Int32(5))
println("Wasm: catch_and_return(5) = $r1 -- $(r1 == 6 ? "CORRECT" : "MISMATCH")")
r2 = run_wasm(bytes, "catch_and_return", Int32(-3))
println("Wasm: catch_and_return(-3) = $r2 -- $(r2 == -1 ? "CORRECT" : "MISMATCH")")

# Now test with stack trace import
# Write a node.js test that captures stack traces
dir = mktempdir()
wasm_path = joinpath(dir, "module.wasm")
js_path = joinpath(dir, "test_trace.mjs")
write(wasm_path, bytes)

# The JS test will try to see if function names appear in the stack trace
js_code = """
import fs from 'fs';
const bytes = fs.readFileSync('$(escape_string(wasm_path))');
const importObject = {
    Math: { pow: Math.pow },
    env: {
        capture_stack: () => new Error().stack
    }
};
const wasmModule = await WebAssembly.instantiate(bytes, importObject);
const result = wasmModule.instance.exports.catch_and_return(-3);
console.log("result:", result);

// Try calling might_throw directly to see the error trace
try {
    wasmModule.instance.exports.might_throw(-1);
} catch (e) {
    console.log("Caught error, stack includes wasm names:", e.stack ? e.stack.includes("might_throw") || e.stack.includes("wasm") : "no stack");
    console.log("Stack:", e.stack ? e.stack.substring(0, 200) : "none");
}
"""
open(js_path, "w") do io
    print(io, js_code)
end
result = read(`node $js_path`, String)
println("\nNode.js stack trace test:")
println(result)
