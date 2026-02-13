#!/usr/bin/env julia
# PURE-324 attempt 23: Root cause is prev_byte=0 inside _bump_until_n
# byte_span = tok.next_byte(2) - prev_byte(0) = 2 → WRONG (should be 1)
# prev_byte should be stream.next_byte = 1
# WHY is prev_byte 0? Either:
# A. i != stream.lookahead_index (comparison fails) → reads lookahead[0] OOB
# B. stream.next_byte reads as 0 inside the function

using WasmTarget, JuliaSyntax

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm(f, func_name::String, test_string::String; expected=nothing)
    bytes = compile(f, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = 0
    try; nfuncs = length(filter(l -> contains(l, "(func"), readlines(`wasm-tools print $tmpf`))); catch; end
    valid = try; run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull)); true; catch; false; end
    if !valid; println("  $func_name: VALIDATE_FAIL ($nfuncs funcs)"); return nothing; end
    js = """
    const fs = require('fs');
    const runtimeCode = fs.readFileSync('$(escape_string(RUNTIME_JS))', 'utf-8');
    const WasmTargetRuntime = new Function(runtimeCode + '\\nreturn WasmTargetRuntime;')();
    (async () => {
        const rt = new WasmTargetRuntime();
        const wasmBytes = fs.readFileSync('$(escape_string(tmpf))');
        const mod = await rt.load(wasmBytes, 'test');
        const func = mod.exports['$func_name'];
        if (!func) { console.log('EXPORT_NOT_FOUND'); process.exit(1); }
        const s = await rt.jsToWasmString($(repr(test_string)));
        try {
            const result = func(s);
            console.log(typeof result === 'bigint' ? result.toString() : JSON.stringify(result));
        } catch (e) { console.log('ERROR: ' + e.message); }
    })();
    """
    js_path = tempname() * ".js"
    write(js_path, js)
    result = try; strip(read(`node $js_path`, String)); catch; "CRASH"; end
    status = if expected !== nothing && result == string(expected)
        "CORRECT ✓"
    elseif expected !== nothing
        "MISMATCH ✗ (expected=$expected)"
    else ""; end
    println("  $func_name(\"$test_string\"): $result $status ($nfuncs funcs)")
    return result
end

# Test 1: Read stream.next_byte inside a function that takes stream as arg
println("=== Test 1: Read stream.next_byte via function parameter ===")
function read_nb_via_param(ps::JuliaSyntax.ParseStream)
    return Int64(ps.next_byte)
end
function test_nb_param(s::String)
    ps = JuliaSyntax.ParseStream(s)
    return read_nb_via_param(ps)
end
native_1 = test_nb_param("1")
println("  Native: $native_1")
test_wasm(test_nb_param, "test_nb_param", "1"; expected=native_1)

# Test 2: Read stream.next_byte INSIDE _bump_until_n's scope
# Write a function that mimics _bump_until_n's first step
println("\n=== Test 2: Simulate prev_byte = stream.next_byte in separate function ===")
function get_prev_byte(stream::JuliaSyntax.ParseStream, i::Int)
    if i == stream.lookahead_index
        return Int64(stream.next_byte)
    else
        return Int64(-999)  # Should not happen
    end
end
function test_prev_byte_func(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    i = ps.lookahead_index
    return get_prev_byte(ps, i)
end
native_2 = test_prev_byte_func("1")
println("  Native: $native_2")
test_wasm(test_prev_byte_func, "test_prev_byte_func", "1"; expected=native_2)

# Test 3: Test i == stream.lookahead_index comparison
println("\n=== Test 3: i == stream.lookahead_index comparison ===")
function test_eq_compare(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    i = ps.lookahead_index  # Should be 1
    # Directly compare
    return i == ps.lookahead_index ? Int64(1) : Int64(0)
end
native_3 = test_eq_compare("1")
println("  Native: $native_3 (should be 1)")
test_wasm(test_eq_compare, "test_eq_compare", "1"; expected=native_3)

# Test 4: Test comparison in a separate function (cross-function)
println("\n=== Test 4: Cross-function i == lookahead_index ===")
function check_eq(stream::JuliaSyntax.ParseStream, i::Int)
    return i == stream.lookahead_index ? Int64(1) : Int64(0)
end
function test_cross_eq(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    return check_eq(ps, ps.lookahead_index)
end
native_4 = test_cross_eq("1")
println("  Native: $native_4 (should be 1)")
test_wasm(test_cross_eq, "test_cross_eq", "1"; expected=native_4)

# Test 5: Full simulation — compute byte_span in a helper function
println("\n=== Test 5: Cross-function byte_span computation ===")
function compute_byte_span(stream::JuliaSyntax.ParseStream, i::Int, tok_nb::UInt32)
    if i == stream.lookahead_index
        prev = stream.next_byte
    else
        prev = 0  # Shouldn't happen
    end
    return Int64(Int(tok_nb) - Int(prev))
end
function test_cross_span(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    tok = ps.lookahead[ps.lookahead_index]
    return compute_byte_span(ps, ps.lookahead_index, tok.next_byte)
end
native_5 = test_cross_span("1")
println("  Native: $native_5 (should be 1)")
test_wasm(test_cross_span, "test_cross_span", "1"; expected=native_5)

# Test 6: Read stream.next_byte as Int (not Int64) — check type
println("\n=== Test 6: stream.next_byte type test (Int vs Int64) ===")
function test_nb_type(s::String)
    ps = JuliaSyntax.ParseStream(s)
    nb = ps.next_byte
    # nb is Int (Int64 on 64-bit). Convert to Int64 explicitly.
    return Int64(nb)
end
native_6 = test_nb_type("1")
println("  Native: $native_6")
test_wasm(test_nb_type, "test_nb_type", "1"; expected=native_6)

println("\nDone!")
