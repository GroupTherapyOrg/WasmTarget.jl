#!/usr/bin/env julia
# PURE-324 attempt 23: Root cause — byte_span is 2 instead of 1
# The calculation: byte_span = Int(tok.next_byte) - Int(prev_byte)
# where prev_byte = stream.next_byte when i == stream.lookahead_index
# Need to test: is prev_byte correct? Is the subtraction correct?
using WasmTarget, JuliaSyntax

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm(f, func_name::String, test_string::String; expected=nothing)
    bytes = compile(f, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = 0
    try
        nfuncs = length(filter(l -> contains(l, "(func"), readlines(`wasm-tools print $tmpf`)))
    catch; end
    valid = try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull))
        true
    catch; false; end
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

# Test: Simulated _bump_until_n — compute byte_span manually
# In _bump_until_n, for the first iteration:
#   prev_byte = stream.next_byte (when i == stream.lookahead_index)
#   byte_span = Int(tok.next_byte) - Int(prev_byte)

# Test A: Compute prev_byte (which should be stream.next_byte at first iter)
println("=== Test A: stream.next_byte before bump (= prev_byte for first token) ===")
function test_prev_byte(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)  # fill lookahead
    return Int64(ps.next_byte)  # this is what prev_byte should be
end
native_a = test_prev_byte("1")
println("  Native: $native_a")
test_wasm(test_prev_byte, "test_prev_byte", "1"; expected=native_a)

# Test B: Compute tok.next_byte for first lookahead token
println("\n=== Test B: tok.next_byte (lookahead[lookahead_index]) ===")
function test_tok_next_byte(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    tok = ps.lookahead[ps.lookahead_index]
    return Int64(tok.next_byte)
end
native_b = test_tok_next_byte("1")
println("  Native: $native_b")
test_wasm(test_tok_next_byte, "test_tok_next_byte", "1"; expected=native_b)

# Test C: Compute byte_span = tok.next_byte - prev_byte manually
println("\n=== Test C: Manual byte_span = tok.next_byte - stream.next_byte ===")
function test_byte_span_manual(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    tok = ps.lookahead[ps.lookahead_index]
    return Int64(tok.next_byte) - Int64(ps.next_byte)
end
native_c = test_byte_span_manual("1")
println("  Native: $native_c (should be 1)")
test_wasm(test_byte_span_manual, "test_byte_span_manual", "1"; expected=native_c)

# Test D: Same for "hello"
println("\n=== Test D: Manual byte_span for 'hello' ===")
native_d = test_byte_span_manual("hello")
println("  Native: $native_d (should be 5)")
test_wasm(test_byte_span_manual, "test_byte_span_manual", "hello"; expected=native_d)

# Test E: Check if the sentinel's byte_span is correct
println("\n=== Test E: Sentinel node byte_span ===")
function test_sentinel_span(s::String)
    ps = JuliaSyntax.ParseStream(s)
    sentinel = first(ps.output)
    return Int64(sentinel.byte_span)
end
native_e = test_sentinel_span("1")
println("  Native: $native_e (should be 0 for index=1)")
test_wasm(test_sentinel_span, "test_sentinel_span", "1"; expected=native_e)

# Test F: Simple subtraction test (not related to parsing)
println("\n=== Test F: Simple Int64 subtraction ===")
function test_sub(s::String)
    a = Int64(2)
    b = Int64(1)
    return a - b
end
native_f = test_sub("x")
println("  Native: $native_f")
test_wasm(test_sub, "test_sub", "x"; expected=native_f)

# Test G: Struct field read — ParseStreamPosition.byte_index
# The sentinel in _bump_until_n:
# sentinel = RawGreenNode(SyntaxHead(K"TOMBSTONE", EMPTY_FLAGS), next_byte-1, K"TOMBSTONE")
# For index=1: next_byte-1 = 0, so sentinel.byte_span = 0
# Check if we can read fields from structs correctly
println("\n=== Test G: Int conversion (Int vs Int64) ===")
function test_int_conv(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    tok = ps.lookahead[ps.lookahead_index]
    # tok.next_byte is an Int — what type is it in Wasm?
    return Int64(tok.next_byte)
end
native_g = test_int_conv("1")
println("  Native: $native_g")
test_wasm(test_int_conv, "test_int_conv", "1"; expected=native_g)

println("\nDone!")
