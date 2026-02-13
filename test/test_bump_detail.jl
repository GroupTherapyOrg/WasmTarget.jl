#!/usr/bin/env julia
# PURE-324 attempt 23: Narrow the next_byte bug in bump()
# FINDING: bump() produces correct output nodes but wrong next_byte
# Test: what are the intermediate values?
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

# Test 1: next_byte BEFORE bump
println("=== Test 1: next_byte before bump ===")
function test_nb_before(s::String)
    ps = JuliaSyntax.ParseStream(s)
    return Int64(ps.next_byte)
end
native_1 = test_nb_before("1")
println("  Native: $native_1")
test_wasm(test_nb_before, "test_nb_before", "1"; expected=native_1)

# Test 2: SyntaxToken next_byte from lookahead (the token's stored value)
println("\n=== Test 2: Lookahead token next_byte ===")
function test_tok_nb(s::String)
    ps = JuliaSyntax.ParseStream(s)
    # Force lookahead fill by peeking
    JuliaSyntax.peek(ps)
    # Get first token from lookahead
    tok = ps.lookahead[ps.lookahead_index]
    return Int64(tok.next_byte)
end
native_2 = test_tok_nb("1")
println("  Native: $native_2 (should be 2 for single byte '1')")
test_wasm(test_tok_nb, "test_tok_nb", "1"; expected=native_2)

# Test 3: What is lookahead_index value?
println("\n=== Test 3: lookahead_index before bump ===")
function test_la_idx(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.peek(ps)
    return Int64(ps.lookahead_index)
end
native_3 = test_la_idx("1")
println("  Native: $native_3")
test_wasm(test_la_idx, "test_la_idx", "1"; expected=native_3)

# Test 4: RawGreenNode byte_span after bump
println("\n=== Test 4: Last output node byte_span after bump ===")
function test_node_span(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.bump(ps)
    # Get the last node (the one just pushed by bump)
    node = last(ps.output)
    return Int64(node.byte_span)
end
native_4 = test_node_span("1")
println("  Native: $native_4 (should be 1 for single byte '1')")
test_wasm(test_node_span, "test_node_span", "1"; expected=native_4)

# Test 5: next_byte after bump with longer string
println("\n=== Test 5: next_byte after bump with 'hello' ===")
function test_nb_hello(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.bump(ps)
    return Int64(ps.next_byte)
end
native_5 = test_nb_hello("hello")
println("  Native: $native_5 (should be 6 for 'hello')")
test_wasm(test_nb_hello, "test_nb_hello", "hello"; expected=native_5)

# Test 6: next_byte after bump with "ab" (2 bytes)
println("\n=== Test 6: next_byte after bump with 'ab' ===")
native_6 = test_nb_hello("ab")
println("  Native: $native_6 (should be 3 for 'ab')")
test_wasm(test_nb_hello, "test_nb_hello", "ab"; expected=native_6)

# Test 7: Multiple bumps — bump Integer then check if EndMarker bump changes next_byte
println("\n=== Test 7: next_byte after TWO bumps ===")
function test_nb_two_bumps(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.bump(ps)
    # Second bump should get EndMarker but _bump_until_n skips it
    JuliaSyntax.bump(ps)
    return Int64(ps.next_byte)
end
native_7 = test_nb_two_bumps("1")
println("  Native: $native_7")
test_wasm(test_nb_two_bumps, "test_nb_two_bumps", "1"; expected=native_7)

println("\nDone!")
