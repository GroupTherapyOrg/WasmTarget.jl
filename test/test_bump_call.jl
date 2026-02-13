#!/usr/bin/env julia
# PURE-324 attempt 23: Test _bump_until_n directly vs via bump()
# Finding: mimic of _bump_until_n works, but bump() call produces wrong next_byte
# Hypothesis: cross-function call issue between bump() and _bump_until_n
using WasmTarget, JuliaSyntax

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm(f, func_name::String, test_string::String; expected=nothing)
    bytes = compile(f, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = 0
    try; nfuncs = length(filter(l -> contains(l, "(func"), readlines(`wasm-tools print $tmpf`))); catch; end
    valid = try; run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull)); true; catch; false; end
    if !valid
        println("  $func_name: VALIDATE_FAIL ($nfuncs funcs)")
        return nothing
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

# Test 1: Call _bump_until_n directly (bypassing bump wrapper)
println("=== Test 1: Direct _bump_until_n call ===")
function test_direct_bump(s::String)
    ps = JuliaSyntax.ParseStream(s)
    # Fill lookahead
    idx = JuliaSyntax._lookahead_index(ps, 1, false)
    # Call _bump_until_n directly
    JuliaSyntax._bump_until_n(ps, idx, JuliaSyntax.EMPTY_FLAGS)
    return Int64(ps.next_byte)
end
native_1 = test_direct_bump("1")
println("  Native: $native_1")
test_wasm(test_direct_bump, "test_direct_bump", "1"; expected=native_1)

# Test 2: Call bump() (the wrapper)
println("\n=== Test 2: bump() wrapper call ===")
function test_bump_wrapper(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.bump(ps)
    return Int64(ps.next_byte)
end
native_2 = test_bump_wrapper("1")
println("  Native: $native_2")
test_wasm(test_bump_wrapper, "test_bump_wrapper", "1"; expected=native_2)

# Test 3: Call _bump_until_n with remap_kind parameter (as bump does)
println("\n=== Test 3: Direct _bump_until_n with K\"None\" remap ===")
function test_direct_bump_remap(s::String)
    ps = JuliaSyntax.ParseStream(s)
    idx = JuliaSyntax._lookahead_index(ps, 1, false)
    JuliaSyntax._bump_until_n(ps, idx, JuliaSyntax.EMPTY_FLAGS, JuliaSyntax.K"None")
    return Int64(ps.next_byte)
end
native_3 = test_direct_bump_remap("1")
println("  Native: $native_3")
test_wasm(test_direct_bump_remap, "test_direct_bump_remap", "1"; expected=native_3)

# Test 4: Check output length after direct _bump_until_n
println("\n=== Test 4: Direct _bump_until_n — output length ===")
function test_direct_bump_outlen(s::String)
    ps = JuliaSyntax.ParseStream(s)
    idx = JuliaSyntax._lookahead_index(ps, 1, false)
    JuliaSyntax._bump_until_n(ps, idx, JuliaSyntax.EMPTY_FLAGS)
    return Int64(length(ps.output))
end
native_4 = test_direct_bump_outlen("1")
println("  Native: $native_4")
test_wasm(test_direct_bump_outlen, "test_direct_bump_outlen", "1"; expected=native_4)

# Test 5: Check byte_span of output node after direct _bump_until_n
println("\n=== Test 5: Direct _bump_until_n — last node byte_span ===")
function test_direct_bump_span(s::String)
    ps = JuliaSyntax.ParseStream(s)
    idx = JuliaSyntax._lookahead_index(ps, 1, false)
    JuliaSyntax._bump_until_n(ps, idx, JuliaSyntax.EMPTY_FLAGS)
    return Int64(last(ps.output).byte_span)
end
native_5 = test_direct_bump_span("1")
println("  Native: $native_5")
test_wasm(test_direct_bump_span, "test_direct_bump_span", "1"; expected=native_5)

# Test 6: Check what _lookahead_index returns
println("\n=== Test 6: _lookahead_index value ===")
function test_la_val(s::String)
    ps = JuliaSyntax.ParseStream(s)
    return Int64(JuliaSyntax._lookahead_index(ps, 1, false))
end
native_6 = test_la_val("1")
println("  Native: $native_6")
test_wasm(test_la_val, "test_la_val", "1"; expected=native_6)

println("\nDone!")
