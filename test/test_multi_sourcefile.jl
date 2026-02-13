#!/usr/bin/env julia
# Test: compile SourceFile in a multi-function module to find divergence
using WasmTarget, JuliaSyntax

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm_string_multi(funcs_to_compile, test_func_name::String, test_string::String)
    bytes = compile_multi(funcs_to_compile)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    println("    Compiled: $(length(bytes)) bytes")

    # Count funcs
    nfuncs = length(filter(l -> contains(l, "(func"), readlines(`wasm-tools print $tmpf`)))
    println("    Functions: $nfuncs")

    # Validate
    try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull))
        println("    Validates: YES")
    catch
        println("    Validates: NO")
        return "VALIDATE_FAIL"
    end

    js = """
    const fs = require('fs');
    const runtimeCode = fs.readFileSync('$(escape_string(RUNTIME_JS))', 'utf-8');
    const WasmTargetRuntime = new Function(runtimeCode + '\\nreturn WasmTargetRuntime;')();

    (async () => {
        const rt = new WasmTargetRuntime();
        const wasmBytes = fs.readFileSync('$(escape_string(tmpf))');
        const mod = await rt.load(wasmBytes, 'test');
        const func = mod.exports['$test_func_name'];
        if (!func) {
            const exports = Object.keys(mod.exports).filter(k => typeof mod.exports[k] === 'function');
            console.log('EXPORT_NOT_FOUND: ' + exports.join(', '));
            process.exit(1);
        }
        const s = await rt.jsToWasmString($(repr(test_string)));
        try {
            const result = func(s);
            if (typeof result === 'bigint') {
                console.log(result.toString());
            } else {
                console.log(JSON.stringify(result));
            }
        } catch (e) {
            console.log('ERROR: ' + e.message);
        }
    })();
    """

    js_path = tempname() * ".js"
    write(js_path, js)

    try
        return strip(read(`node $js_path`, String))
    catch
        return "CRASH"
    end
end

# Test 1: Single function (baseline — should pass)
println("=== Test 1: Single function (baseline) ===")
sf_line_count(s::String) = begin
    line_starts = Int[1]
    for i in eachindex(s)
        s[i] == '\n' && push!(line_starts, i+1)
    end
    length(line_starts)
end
result = test_wasm_string_multi(
    [(sf_line_count, (String,))],
    "sf_line_count", "1"
)
println("    Result: $result (expected: 1)")

# Test 2: SourceFile constructor (single function with dependencies auto-discovered)
println("\n=== Test 2: SourceFile constructor ===")
sf_full_lines(s::String) = length(SourceFile(s).line_starts)
result = test_wasm_string_multi(
    [(sf_full_lines, (String,))],
    "sf_full_lines", "1"
)
println("    Result: $result (expected: 1)")

# Test 3: Parse with ParseStream — this gets closer to parsestmt
println("\n=== Test 3: ParseStream creation ===")
function make_parsestream(s::String)
    ps = JuliaSyntax.ParseStream(s)
    return Int64(1)
end
result = test_wasm_string_multi(
    [(make_parsestream, (String,))],
    "make_parsestream", "1"
)
println("    Result: $result (expected: 1)")

println("\nDone!")
