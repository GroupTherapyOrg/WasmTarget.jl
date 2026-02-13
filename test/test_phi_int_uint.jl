#!/usr/bin/env julia
# PURE-324 attempt 23: Test phi merge of Int64 and UInt32
# HYPOTHESIS: When a phi node merges Int64 from one branch and UInt32 from another,
# the codegen mishandles the type widening, producing 0 for the Int64 path.
using WasmTarget

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm_int(f, func_name::String, arg::Int64; expected=nothing)
    bytes = compile(f, (Int64,))
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
        try {
            const result = func(BigInt($arg));
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
    println("  $func_name($arg): $result $status ($nfuncs funcs)")
    return result
end

# Test 1: Simple phi with Int64 on both sides (should work)
println("=== Test 1: Phi with Int64/Int64 ===")
function test_phi_i64(flag::Int64)
    a = Int64(42)
    b = Int64(17)
    result = flag > Int64(0) ? a : b
    return result
end
native_1 = test_phi_i64(Int64(1))
println("  Native(1): $native_1")
test_wasm_int(test_phi_i64, "test_phi_i64", Int64(1); expected=native_1)
native_1b = test_phi_i64(Int64(0))
println("  Native(0): $native_1b")
test_wasm_int(test_phi_i64, "test_phi_i64", Int64(0); expected=native_1b)

# Test 2: Phi merging Int64 and UInt32 (the suspect pattern)
println("\n=== Test 2: Phi with Int64/UInt32 ===")
function test_phi_mixed(flag::Int64)
    a = Int64(42)        # Int64
    b = UInt32(17)       # UInt32
    result = flag > Int64(0) ? a : b
    return Int64(result)
end
native_2t = test_phi_mixed(Int64(1))
println("  Native(1): $native_2t (should be 42)")
test_wasm_int(test_phi_mixed, "test_phi_mixed", Int64(1); expected=native_2t)
native_2f = test_phi_mixed(Int64(0))
println("  Native(0): $native_2f (should be 17)")
test_wasm_int(test_phi_mixed, "test_phi_mixed", Int64(0); expected=native_2f)

# Test 3: Same pattern but with subtraction (like _bump_until_n)
println("\n=== Test 3: Phi merge then subtract ===")
function test_phi_sub(flag::Int64)
    a = Int64(1)         # stream.next_byte (Int64)
    b = UInt32(0)        # lookahead[i-1].next_byte (UInt32)
    prev = flag > Int64(0) ? a : b
    tok_nb = UInt32(2)   # tok.next_byte (UInt32)
    byte_span = Int(tok_nb) - Int(prev)
    return Int64(byte_span)
end
native_3t = test_phi_sub(Int64(1))
println("  Native(1): $native_3t (should be 1 = 2 - 1)")
test_wasm_int(test_phi_sub, "test_phi_sub", Int64(1); expected=native_3t)
native_3f = test_phi_sub(Int64(0))
println("  Native(0): $native_3f (should be 2 = 2 - 0)")
test_wasm_int(test_phi_sub, "test_phi_sub", Int64(0); expected=native_3f)

# Test 4: More realistic pattern — struct fields with different types
println("\n=== Test 4: Struct field phi ===")
struct TokenLike
    next_byte::UInt32
end
mutable struct StreamLike
    next_byte::Int64
    tokens::Vector{TokenLike}
    idx::Int64
end
function test_struct_phi(flag::Int64)
    stream = StreamLike(Int64(1), [TokenLike(UInt32(0))], Int64(1))
    tok = TokenLike(UInt32(2))
    if flag == stream.idx
        prev = stream.next_byte    # Int64
    else
        prev = stream.tokens[1].next_byte  # UInt32
    end
    byte_span = Int(tok.next_byte) - Int(prev)
    return Int64(byte_span)
end
native_4 = test_struct_phi(Int64(1))
println("  Native(1): $native_4 (should be 1 = 2 - 1)")
test_wasm_int(test_struct_phi, "test_struct_phi", Int64(1); expected=native_4)

println("\nDone!")
