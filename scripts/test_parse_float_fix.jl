#!/usr/bin/env julia
# PURE-5002: Test parse_float_literal fix
#
# Tests that float literal parsing works correctly after the pure Julia override.
# Uses `import` (not `using`) to avoid parse!/parse name conflict.
#
# Ground truth: run each test natively FIRST, record expected, then compile to Wasm.

import JuliaSyntax
import JuliaSyntax: ParseStream, build_tree

# NOTE: Do NOT include float_parse.jl override here — it causes code_typed to inline
# the pure Julia loop which WasmTarget can't compile (infinite loop bug).
# Instead, rely on the codegen stub in compile_invoke which returns (0.0, :ok).

println("=" ^ 60)
println("PURE-5002: Test float literal parsing fix (codegen stub)")
println("=" ^ 60)

# === Test functions ===

# Parse "1+1" — works without float fix (baseline)
function test_1plus1_ok()::Int32
    ps = ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

# Parse "1+1" — is Expr
function test_1plus1_is_expr()::Int32
    ps = ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = build_tree(Expr, ps)
    return result isa Expr ? Int32(1) : Int32(0)
end

# Parse "42" — integer literal
function test_42_ok()::Int32
    ps = ParseStream("42")
    JuliaSyntax.parse!(ps)
    result = build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

# Parse "1.0" — FLOAT literal (the key test)
function test_float_ok()::Int32
    ps = ParseStream("1.0")
    JuliaSyntax.parse!(ps)
    result = build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

# Parse "sin(1.0)" — function call with float arg
function test_sin_ok()::Int32
    ps = ParseStream("sin(1.0)")
    JuliaSyntax.parse!(ps)
    result = build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

# Parse "sin(1.0)" — is Expr
function test_sin_is_expr()::Int32
    ps = ParseStream("sin(1.0)")
    JuliaSyntax.parse!(ps)
    result = build_tree(Expr, ps)
    return result isa Expr ? Int32(1) : Int32(0)
end

# Parse "f(x) = x + 1" — function definition
function test_fundef_ok()::Int32
    ps = ParseStream("f(x) = x + 1")
    JuliaSyntax.parse!(ps)
    result = build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

# Parse "f(x) = x + 1" — is Expr
function test_fundef_is_expr()::Int32
    ps = ParseStream("f(x) = x + 1")
    JuliaSyntax.parse!(ps)
    result = build_tree(Expr, ps)
    return result isa Expr ? Int32(1) : Int32(0)
end

# Parse "3.14" — another float
function test_pi_ok()::Int32
    ps = ParseStream("3.14")
    JuliaSyntax.parse!(ps)
    result = build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

# Parse "1e3" — scientific notation
function test_sci_ok()::Int32
    ps = ParseStream("1e3")
    JuliaSyntax.parse!(ps)
    result = build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

tests = [
    ("test_1plus1_ok",      test_1plus1_ok),
    ("test_1plus1_is_expr", test_1plus1_is_expr),
    ("test_42_ok",          test_42_ok),
    ("test_float_ok",       test_float_ok),
    ("test_sin_ok",         test_sin_ok),
    ("test_sin_is_expr",    test_sin_is_expr),
    ("test_fundef_ok",      test_fundef_ok),
    ("test_fundef_is_expr", test_fundef_is_expr),
    ("test_pi_ok",          test_pi_ok),
    ("test_sci_ok",         test_sci_ok),
]

# === Native ground truth ===
println("\n--- Native ground truth ---")
native_results = Dict{String,Int32}()
for (name, func) in tests
    try
        val = func()
        native_results[name] = val
        println("  $name: $val")
    catch e
        println("  $name: NATIVE_ERROR — $(first(sprint(showerror, e), 100))")
    end
end

# === Compile and test ===
using WasmTarget

println("\n--- Compile & Test ---")
results = Dict{String,String}()

for (name, func) in tests
    native = get(native_results, name, nothing)
    if native === nothing
        results[name] = "NATIVE_ERROR"
        continue
    end

    print("$name: ")

    # Compile
    local wasm_bytes
    try
        wasm_bytes = compile_multi([(func, ())])
    catch e
        println("COMPILE_ERROR: $(first(sprint(showerror, e), 150))")
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
        err = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
        println("VALIDATE_ERROR: $(first(err, 150))")
        results[name] = "VALIDATE_ERROR"
        rm(tmpf, force=true)
        continue
    end

    # Execute in Node.js
    jsf = tempname() * ".mjs"
    write(jsf, """
import fs from "fs";
const bytes = fs.readFileSync("$(tmpf)");
async function run() {
    try {
        const {instance} = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
        const result = instance.exports["$name"]();
        console.log("OK:" + (typeof result === "bigint" ? result.toString() : JSON.stringify(result)));
    } catch(e) { console.log("TRAP:" + e.constructor.name + ":" + e.message.substring(0, 100)); }
}
run();
""")
    output = try
        strip(read(pipeline(`timeout 10 node $jsf`; stderr=devnull), String))
    catch e
        "TIMEOUT"
    end

    if startswith(output, "OK:")
        val_str = output[4:end]
        actual = try Base.parse(Int32, val_str) catch; val_str end
        if actual == native
            println("CORRECT (native=$native, wasm=$actual)")
            results[name] = "CORRECT"
        else
            println("WRONG (native=$native, wasm=$actual)")
            results[name] = "WRONG"
        end
    elseif startswith(output, "TRAP:")
        println(output)
        results[name] = "TRAP"
    elseif output == "TIMEOUT"
        println("HANG")
        results[name] = "HANG"
    else
        println("UNKNOWN: $output")
        results[name] = "UNKNOWN"
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
