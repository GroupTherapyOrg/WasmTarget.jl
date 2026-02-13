#!/usr/bin/env julia
# Standalone test: compile SourceFile-related functions and test in Node.js
# Uses wasmtarget-runtime.js for proper String ↔ Wasm conversion
using WasmTarget
using JuliaSyntax

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm_with_string(f, func_name::String, test_string::String; timeout_sec=10)
    bytes = compile(f, (SubString{String},))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    # Validate first
    try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull))
    catch
        println("  FAIL: validation error")
        return false
    end

    # Create Node.js test script
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
            console.log('FAIL: export not found');
            process.exit(1);
        }
        const s = await rt.jsToWasmString($(repr(test_string)));
        try {
            const result = func(s);
            // Handle BigInt
            if (typeof result === 'bigint') {
                console.log(result.toString());
            } else {
                console.log(JSON.stringify(result));
            }
        } catch (e) {
            console.log('ERROR: ' + e.message);
            process.exit(1);
        }
    })();
    """

    js_path = tempname() * ".js"
    write(js_path, js)

    try
        output = strip(read(`node $js_path`, String))
        return output
    catch e
        return "CRASH"
    end
end

function test_wasm_with_string_arg(f, func_name::String, test_string::String)
    bytes = compile(f, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull))
    catch
        println("  FAIL: validation error")
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
            console.log('FAIL: export not found');
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
            process.exit(1);
        }
    })();
    """

    js_path = tempname() * ".js"
    write(js_path, js)

    try
        output = strip(read(`node $js_path`, String))
        return output
    catch e
        return "CRASH"
    end
end

# ============================================================
# Test 1: eachindex + codeunit on String (simplest version)
# ============================================================
println("=== Test 1: Count newlines in String ===")
function count_nl_str(s::String)
    n = Int64(0)
    for i in eachindex(s)
        codeunit(s, i) == 0x0a && (n += Int64(1))
    end
    return n
end

for input in ["hello", "a\nb", "a\nb\nc\n"]
    result = test_wasm_with_string_arg(count_nl_str, "count_nl_str", input)
    expected = count_nl_str(input)
    status = result == string(expected) ? "PASS" : "FAIL"
    println("  count_nl_str($(repr(input))): $status (expected=$expected, got=$result)")
end

# ============================================================
# Test 2: String getindex (s[i] == '\n')
# ============================================================
println("\n=== Test 2: String getindex loop ===")
function count_nl_getindex(s::String)
    n = Int64(0)
    for i in eachindex(s)
        s[i] == '\n' && (n += Int64(1))
    end
    return n
end

for input in ["hello", "a\nb"]
    result = test_wasm_with_string_arg(count_nl_getindex, "count_nl_getindex", input)
    expected = count_nl_getindex(input)
    status = result == string(expected) ? "PASS" : "FAIL"
    println("  count_nl_getindex($(repr(input))): $status (expected=$expected, got=$result)")
end

# ============================================================
# Test 3: SubString + eachindex + getindex
# ============================================================
println("\n=== Test 3: SubString getindex loop ===")
function count_nl_substr(ss::SubString{String})
    n = Int64(0)
    for i in eachindex(ss)
        ss[i] == '\n' && (n += Int64(1))
    end
    return n
end

for input in ["hello", "a\nb"]
    ss = SubString(input, 1, length(input))
    result = test_wasm_with_string(count_nl_substr, "count_nl_substr", input)
    expected = count_nl_substr(ss)
    status = result == string(expected) ? "PASS" : "FAIL"
    println("  count_nl_substr($(repr(input))): $status (expected=$expected, got=$result)")
end

# ============================================================
# Test 4: push! into Vector{Int} (line_starts pattern)
# ============================================================
println("\n=== Test 4: Vector push! pattern ===")
function make_line_starts_str(s::String)
    line_starts = Int[1]
    for i in eachindex(s)
        s[i] == '\n' && push!(line_starts, i + 1)
    end
    return length(line_starts)
end

for input in ["hello", "a\nb", "a\nb\nc\n"]
    result = test_wasm_with_string_arg(make_line_starts_str, "make_line_starts_str", input)
    expected = make_line_starts_str(input)
    status = result == string(expected) ? "PASS" : "FAIL"
    println("  make_line_starts_str($(repr(input))): $status (expected=$expected, got=$result)")
end

println("\nDone!")
