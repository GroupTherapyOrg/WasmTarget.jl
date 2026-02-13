#!/usr/bin/env julia
# PURE-324 attempt 23: Diagnose extra output node in parse!
# Previous findings: Wasm produces +1 extra node (error + toplevel) vs native Julia
# Goal: Find MINIMUM function set that triggers the bug
using WasmTarget, JuliaSyntax

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm(f, func_name::String, test_string::String; expected=nothing)
    bytes = compile(f, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    nfuncs = 0
    try
        nfuncs = length(filter(l -> contains(l, "(func"), readlines(`wasm-tools print $tmpf`)))
    catch
    end

    valid = try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull))
        true
    catch
        false
    end

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

    result = try
        strip(read(`node $js_path`, String))
    catch
        "CRASH"
    end

    status = if expected !== nothing && result == string(expected)
        "CORRECT"
    elseif expected !== nothing
        "MISMATCH (expected=$expected)"
    else
        ""
    end

    println("  $func_name(\"$test_string\"): $result $status ($nfuncs funcs)")
    return result
end

# Ground truth from native Julia
println("=== Native Julia ground truth ===")
for input in ["1", "hello", "1+2"]
    ps = JuliaSyntax.ParseStream(input)
    JuliaSyntax.parse!(ps; rule=:statement)
    println("  parse!(\"$input\", rule=:statement): output_length=$(length(ps.output)), next_byte=$(ps.next_byte)")
end
println()
for input in ["1", "hello", "1+2"]
    ps = JuliaSyntax.ParseStream(input)
    JuliaSyntax.parse!(ps; rule=:all)
    println("  parse!(\"$input\", rule=:all): output_length=$(length(ps.output)), next_byte=$(ps.next_byte)")
end

println()

# Test 1: parse! with rule=:statement, return output length
println("=== Test: parse! output count (rule=:statement) ===")
function test_output_stmt(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(ps; rule=:statement)
    return Int64(length(ps.output))
end
native_stmt = test_output_stmt("1")
println("  Native: test_output_stmt(\"1\") = $native_stmt")
test_wasm(test_output_stmt, "test_output_stmt", "1"; expected=native_stmt)

println()

# Test 2: parse! with rule=:all, return output length
println("=== Test: parse! output count (rule=:all) ===")
function test_output_all(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(ps; rule=:all)
    return Int64(length(ps.output))
end
native_all = test_output_all("1")
println("  Native: test_output_all(\"1\") = $native_all")
test_wasm(test_output_all, "test_output_all", "1"; expected=native_all)

println()

# Test 3: parse! return next_byte
println("=== Test: parse! next_byte (rule=:statement) ===")
function test_nb_stmt(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(ps; rule=:statement)
    return Int64(ps.next_byte)
end
native_nb = test_nb_stmt("1")
println("  Native: test_nb_stmt(\"1\") = $native_nb")
test_wasm(test_nb_stmt, "test_nb_stmt", "1"; expected=native_nb)

println()

# Test 4: parse_Nary return value (does it return true or false?)
# parse_Nary returns true when n_delims != 0 or when k in closing_tokens
# For "1" with delimiters=(K";",), closing_tokens=(K"NewlineWs",), should return false
println("=== Test: parse_Nary return value ===")
function test_nary_return(s::String)
    ps = JuliaSyntax.ParseStream(s)
    state = JuliaSyntax.ParseState(ps)
    result = JuliaSyntax.parse_Nary(state, JuliaSyntax.parse_public, (JuliaSyntax.K";",), (JuliaSyntax.K"NewlineWs",))
    return result ? Int64(1) : Int64(0)
end
native_nary = test_nary_return("1")
println("  Native: test_nary_return(\"1\") = $native_nary ($(native_nary == 0 ? "false" : "true"))")
test_wasm(test_nary_return, "test_nary_return", "1"; expected=native_nary)

println("\nDone!")
