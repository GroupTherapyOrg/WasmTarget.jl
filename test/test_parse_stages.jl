#!/usr/bin/env julia
# PURE-324 attempt 23: Trace which stage creates the extra output node
# Key: test output count at different stages of the parse pipeline
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
    else
        ""
    end
    println("  $func_name(\"$test_string\"): $result $status ($nfuncs funcs)")
    return result
end

# Stage A: Just ParseStream creation — output count after constructor
println("=== Stage A: ParseStream constructor ===")
function test_ps_init(s::String)
    ps = JuliaSyntax.ParseStream(s)
    return Int64(length(ps.output))
end
native_a = test_ps_init("1")
println("  Native: $native_a")
test_wasm(test_ps_init, "test_ps_init", "1"; expected=native_a)

# Stage B: After bump_trivia (the pre-parse step from _parse)
println("\n=== Stage B: After bump_trivia ===")
function test_after_trivia(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.bump_trivia(ps; skip_newlines=true)
    return Int64(length(ps.output))
end
native_b = test_after_trivia("1")
println("  Native: $native_b")
test_wasm(test_after_trivia, "test_after_trivia", "1"; expected=native_b)

# Stage C: After parse_Nary's bump_trivia (inside parse_stmts)
# This is harder to test directly, but we can test parse! with
# a simple function that doesn't go through the full chain
println("\n=== Stage C: After parse! (statement) — output count ===")
function test_after_parse_stmt(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(ps; rule=:statement)
    return Int64(length(ps.output))
end
native_c = test_after_parse_stmt("1")
println("  Native: $native_c")
test_wasm(test_after_parse_stmt, "test_after_parse_stmt", "1"; expected=native_c)

# Stage D: Output count with rule=:all
println("\n=== Stage D: After parse! (all) — output count ===")
function test_after_parse_all(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(ps; rule=:all)
    return Int64(length(ps.output))
end
native_d = test_after_parse_all("1")
println("  Native: $native_d")
test_wasm(test_after_parse_all, "test_after_parse_all", "1"; expected=native_d)

# Stage E: Check if the bug is in bump specifically
# Test: create ParseStream, manually peek + bump the Integer, check count
println("\n=== Stage E: Manual peek + bump (no parser) ===")
function test_manual_bump(s::String)
    ps = JuliaSyntax.ParseStream(s)
    # Just bump one token manually
    JuliaSyntax.bump(ps)
    return Int64(length(ps.output))
end
native_e = test_manual_bump("1")
println("  Native: $native_e")
test_wasm(test_manual_bump, "test_manual_bump", "1"; expected=native_e)

# Stage F: bump + next_byte
println("\n=== Stage F: Manual bump — next_byte ===")
function test_bump_nb(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.bump(ps)
    return Int64(ps.next_byte)
end
native_f = test_bump_nb("1")
println("  Native: $native_f")
test_wasm(test_bump_nb, "test_bump_nb", "1"; expected=native_f)

println("\nDone!")
