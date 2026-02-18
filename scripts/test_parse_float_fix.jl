#!/usr/bin/env julia
# PURE-5002: Test parse_float_literal codegen stub fix
#
# Tests that the improved parse_float_literal stub (returns Tuple{Float64,Symbol}
# instead of i32.const 0) fixes the float literal TRAP.
#
# Uses same import pattern as compile_parse_stage1.jl which WORKS.

using WasmTarget
using JuliaSyntax

println("=" ^ 60)
println("PURE-5002: Test float literal parsing fix (codegen stub)")
println("=" ^ 60)

# === Test functions (same pattern as compile_parse_stage1.jl) ===

function test_1plus1_ok()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

function test_42_ok()::Int32
    ps = JuliaSyntax.ParseStream("42")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

function test_float_ok()::Int32
    ps = JuliaSyntax.ParseStream("1.0")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

function test_sin_ok()::Int32
    ps = JuliaSyntax.ParseStream("sin(1.0)")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

function test_fundef_ok()::Int32
    ps = JuliaSyntax.ParseStream("f(x) = x + 1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

function test_pi_ok()::Int32
    ps = JuliaSyntax.ParseStream("3.14")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

function test_x_plus_1()::Int32
    ps = JuliaSyntax.ParseStream("x + 1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

function test_fundef_simple()::Int32
    ps = JuliaSyntax.ParseStream("f(x) = x")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

tests = [
    ("test_1plus1_ok",     test_1plus1_ok),
    ("test_42_ok",         test_42_ok),
    ("test_float_ok",      test_float_ok),
    ("test_sin_ok",        test_sin_ok),
    ("test_fundef_ok",     test_fundef_ok),
    ("test_pi_ok",         test_pi_ok),
    ("test_x_plus_1",      test_x_plus_1),
    ("test_fundef_simple", test_fundef_simple),
]

# === Native ground truth ===
println("\n--- Native Julia Ground Truth ---")
native_results = Dict{String,Int32}()
for (name, func) in tests
    r = func()
    println("  $name: $r")
    native_results[name] = r
end

# === Compile and test each ===
println("\n--- Compile & Test ---")
results = Dict{String,String}()

for (name, func) in tests
    native = native_results[name]
    println("\n--- $name (native=$native) ---")

    print("  Compiling: ")
    local wasm_bytes
    try
        wasm_bytes = compile_multi([(func, ())])
        println("$(length(wasm_bytes)) bytes")
    catch e
        println("COMPILE_ERROR: $(first(sprint(showerror, e), 200))")
        results[name] = "COMPILE_ERROR"
        continue
    end

    # Validate
    tmpf = tempname() * ".wasm"
    write(tmpf, wasm_bytes)
    valid = try
        run(`wasm-tools validate --features=gc $tmpf`)
        true
    catch; false end

    if !valid
        valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
        println("  VALIDATE_ERROR: $(first(valerr, 200))")
        results[name] = "VALIDATE_ERROR"
        rm(tmpf, force=true)
        continue
    end
    println("  VALIDATES")

    nfuncs = try
        Base.parse(Int, readchomp(`bash -c "wasm-tools print $tmpf | grep -c '(func ' || true"`))
    catch; -1 end
    println("  Functions: $nfuncs")

    # Test in Node.js
    jsf = tempname() * ".mjs"
    write(jsf, """
import fs from "fs";
const bytes = fs.readFileSync("$(tmpf)");
async function run() {
    try {
        const {instance} = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
        const result = instance.exports['$name']();
        if (typeof result === 'bigint') {
            console.log("RESULT:" + result.toString());
        } else {
            console.log("RESULT:" + JSON.stringify(result));
        }
    } catch(e) {
        console.log("ERROR:" + e.constructor.name + ":" + e.message.substring(0, 100));
    }
}
run();
""")

    output = try
        strip(read(`node $jsf`, String))
    catch e
        "EXEC_ERROR:$(first(sprint(showerror, e), 100))"
    end

    if startswith(output, "RESULT:")
        val_str = output[8:end]
        actual = try Base.parse(Int32, val_str) catch; val_str end
        if actual == native
            println("  CORRECT (native=$native, wasm=$actual)")
            results[name] = "CORRECT"
        else
            println("  WRONG (native=$native, wasm=$actual)")
            results[name] = "WRONG"
        end
    else
        println("  $output")
        results[name] = output
    end

    rm(tmpf, force=true)
    rm(jsf, force=true)
end

# === Summary ===
println("\n" * "=" ^ 60)
println("PURE-5002: Parse Float Fix Results")
println("=" ^ 60)
println("| Test | Native | Wasm | Result |")
println("|------|--------|------|--------|")
for (name, _) in tests
    native = get(native_results, name, "?")
    result = get(results, name, "?")
    println("| $name | $native | - | $result |")
end

correct = count(v -> v == "CORRECT", values(results))
total = length(tests)
println("\n$correct/$total CORRECT")
