#!/usr/bin/env julia
# PURE-324 attempt 23: Mimic _bump_until_n logic to find which step goes wrong
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

# Test 1: Mimic _bump_until_n for first token
# Do exactly what _bump_until_n does, but return byte_span instead of pushing
println("=== Test 1: Mimic _bump_until_n byte_span ===")
function test_mimic_span(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)  # Fill lookahead
    i = ps.lookahead_index
    tok = ps.lookahead[i]
    # Mimic the prev_byte logic
    prev_byte = ps.next_byte  # First token in batch
    byte_span = Int(tok.next_byte) - Int(prev_byte)
    return Int64(byte_span)
end
native_1 = test_mimic_span("1")
println("  Native: $native_1")
test_wasm(test_mimic_span, "test_mimic_span", "1"; expected=native_1)

# Test 2: Mimic with stream.next_byte update (the full iteration)
println("\n=== Test 2: Mimic with next_byte update ===")
function test_mimic_nb(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    i = ps.lookahead_index
    tok = ps.lookahead[i]
    prev_byte = ps.next_byte
    byte_span = Int(tok.next_byte) - Int(prev_byte)
    ps.next_byte += byte_span  # Update like _bump_until_n does
    return Int64(ps.next_byte)
end
native_2 = test_mimic_nb("1")
println("  Native: $native_2")
test_wasm(test_mimic_nb, "test_mimic_nb", "1"; expected=native_2)

# Test 3: Same as test 2 but with "hello"
println("\n=== Test 3: Mimic with next_byte update (hello) ===")
native_3 = test_mimic_nb("hello")
println("  Native: $native_3")
test_wasm(test_mimic_nb, "test_mimic_nb", "hello"; expected=native_3)

# Test 4: Mimic but also create RawGreenNode (as _bump_until_n does)
println("\n=== Test 4: Mimic with RawGreenNode creation ===")
function test_mimic_full(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    i = ps.lookahead_index
    tok = ps.lookahead[i]
    prev_byte = ps.next_byte
    byte_span = Int(tok.next_byte) - Int(prev_byte)

    # Create the node like _bump_until_n does
    k = JuliaSyntax.kind(tok)
    f = JuliaSyntax.flags(tok)
    h = JuliaSyntax.SyntaxHead(k, f)
    node = JuliaSyntax.RawGreenNode(h, byte_span, k)
    push!(ps.output, node)

    ps.next_byte += byte_span
    return Int64(ps.next_byte)
end
native_4 = test_mimic_full("1")
println("  Native: $native_4")
test_wasm(test_mimic_full, "test_mimic_full", "1"; expected=native_4)

# Test 5: Test reading next_byte via getfield directly
println("\n=== Test 5: getfield(tok, :next_byte) ===")
function test_getfield_nb(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    tok = ps.lookahead[ps.lookahead_index]
    return Int64(getfield(tok, :next_byte))
end
native_5 = test_getfield_nb("1")
println("  Native: $native_5")
test_wasm(test_getfield_nb, "test_getfield_nb", "1"; expected=native_5)

# Test 6: Test reading next_byte from stream vs tok
# Make it explicit: read both, print both
println("\n=== Test 6: Return both values (encode as stream_nb * 100 + tok_nb) ===")
function test_both_nb(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    tok = ps.lookahead[ps.lookahead_index]
    stream_nb = Int64(ps.next_byte)
    tok_nb = Int64(tok.next_byte)
    return stream_nb * Int64(100) + tok_nb
end
native_6 = test_both_nb("1")
println("  Native: $native_6 (should be 102 = 1*100 + 2)")
test_wasm(test_both_nb, "test_both_nb", "1"; expected=native_6)

println("\nDone!")
