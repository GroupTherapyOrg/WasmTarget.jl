#!/usr/bin/env julia
# Test: compile the ACTUAL SourceFile constructor and run it
using WasmTarget, JuliaSyntax

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm_string(f, func_name::String, test_string::String)
    bytes = compile(f, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull))
    catch
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
        const func = mod.exports['$func_name'];
        if (!func) {
            console.log('EXPORT_NOT_FOUND');
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

# Test: The actual SourceFile constructor from parsestmt's perspective
# In parsestmt: SourceFile(code; first_index=1) where code is a SubString or String
# Let's test with just the line_starts counting part

println("=== Test A: Exact SourceFile line_starts pattern ===")
function sf_line_count(s::String)
    # This matches SourceFile constructor logic
    line_starts = Int[1]
    for i in eachindex(s)
        s[i] == '\n' && push!(line_starts, i+1)
    end
    return length(line_starts)
end
for input in ["1", "hello", "a\nb", "a\nb\nc"]
    result = test_wasm_string(sf_line_count, "sf_line_count", input)
    expected = sf_line_count(input)
    status = result == string(expected) ? "PASS" : "FAIL"
    println("  sf_line_count($(repr(input))): $status (expected=$expected, got=$result)")
end

# Test: SourceFile constructor returning the number of line_starts
println("\n=== Test B: Full SourceFile then count line_starts ===")
function sf_full_lines(s::String)
    sf = SourceFile(s)
    return length(sf.line_starts)
end
for input in ["1", "hello", "a\nb"]
    result = test_wasm_string(sf_full_lines, "sf_full_lines", input)
    expected = sf_full_lines(input)
    status = result == string(expected) ? "PASS" : "FAIL"
    println("  sf_full_lines($(repr(input))): $status (expected=$expected, got=$result)")
end

# Test: Simple field access on SubString created from String
println("\n=== Test C: SubString field access ===")
function ss_offset(s::String)
    ss = SubString(s)
    return ss.offset
end
result = test_wasm_string(ss_offset, "ss_offset", "hello")
println("  ss_offset('hello'): expected=0, got=$result")

function ss_ncu(s::String)
    ss = SubString(s)
    return ss.ncodeunits
end
result = test_wasm_string(ss_ncu, "ss_ncu", "hello")
println("  ss_ncu('hello'): expected=5, got=$result")

println("\nDone!")
