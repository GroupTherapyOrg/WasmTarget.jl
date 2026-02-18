#!/usr/bin/env julia
# PURE-5002: Stage 1 execution — proper parse_to_expr tests
#
# KEY FINDING: Loading `JSON` causes method ambiguity with JuliaSyntax.parse!
# because JSON defines its own `parse`. This breaks code_typed for functions
# that call parse!(ps). Solution: test WITHOUT loading JSON, use manual
# Node.js test instead of run_wasm harness.
#
# NATIVE JULIA GROUND TRUTH:
#   build_tree(Expr, ParseStream("1+1")) = Expr(:call, :+, 1, 1) — isa Expr, head=:call, nargs=3
#   build_tree(Expr, ParseStream("42"))  = 42 — isa Int64, value=42
#   build_tree(Expr, ParseStream("sin(1.0)")) = Expr(:call, :sin, 1.0) — isa Expr, head=:call, nargs=2
#   build_tree(Expr, ParseStream("f(x) = x + 1")) = Expr(:(=), ...) — isa Expr, head=:(=), nargs=2

using WasmTarget
using JuliaSyntax

println("=" ^ 60)
println("PURE-5002: Stage 1 — parse_to_expr (no JSON conflict)")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════
# Test functions — each compiled individually
# ═══════════════════════════════════════════════════════════════

# Parse "1+1" — not nothing?
function test_1plus1_ok()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

# Parse "1+1" — is Expr?
function test_1plus1_is_expr()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Expr ? Int32(1) : Int32(0)
end

# Parse "1+1" — nargs
function test_1plus1_nargs()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Expr ? Int32(length(result.args)) : Int32(-1)
end

# Parse "42" — not nothing?
function test_42_ok()::Int32
    ps = JuliaSyntax.ParseStream("42")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

# Parse "sin(1.0)" — not nothing?
function test_sin_ok()::Int32
    ps = JuliaSyntax.ParseStream("sin(1.0)")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

# Parse "sin(1.0)" — is Expr?
function test_sin_is_expr()::Int32
    ps = JuliaSyntax.ParseStream("sin(1.0)")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Expr ? Int32(1) : Int32(0)
end

# Parse "f(x) = x + 1" — not nothing?
function test_fundef_ok()::Int32
    ps = JuliaSyntax.ParseStream("f(x) = x + 1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if result === nothing
        return Int32(0)
    end
    return Int32(1)
end

# Parse "f(x) = x + 1" — is Expr?
function test_fundef_is_expr()::Int32
    ps = JuliaSyntax.ParseStream("f(x) = x + 1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Expr ? Int32(1) : Int32(0)
end

# ═══════════════════════════════════════════════════════════════
# Verify native ground truth
# ═══════════════════════════════════════════════════════════════
println("\n--- Native Julia Ground Truth ---")
tests = [
    ("test_1plus1_ok", test_1plus1_ok),
    ("test_1plus1_is_expr", test_1plus1_is_expr),
    ("test_1plus1_nargs", test_1plus1_nargs),
    ("test_42_ok", test_42_ok),
    ("test_sin_ok", test_sin_ok),
    ("test_sin_is_expr", test_sin_is_expr),
    ("test_fundef_ok", test_fundef_ok),
    ("test_fundef_is_expr", test_fundef_is_expr),
]

native_results = Dict{String,Int32}()
for (name, func) in tests
    r = func()
    println("  $name: $r")
    native_results[name] = r
end

# ═══════════════════════════════════════════════════════════════
# Verify IR is valid (not Union{})
# ═══════════════════════════════════════════════════════════════
println("\n--- code_typed check ---")
for (name, func) in tests
    ci = first(Base.code_typed(func, ()))[1]
    println("  $name: rettype=$(ci.rettype), stmts=$(length(ci.code))")
end

# ═══════════════════════════════════════════════════════════════
# Compile and test each
# ═══════════════════════════════════════════════════════════════
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

    # Test in Node.js directly (no JSON harness)
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
        console.log("ERROR:" + e.constructor.name + ":" + e.message);
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

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
println("\n" * "=" ^ 60)
println("PURE-5002: Stage 1 Results")
println("=" ^ 60)
println("| Test | Native | Wasm | Result |")
println("|------|--------|------|--------|")
for (name, _) in tests
    native = native_results[name]
    result = get(results, name, "UNKNOWN")
    println("| $name | $native | $(result) |")
end

correct = count(v -> v == "CORRECT", values(results))
println("\n$correct/$(length(tests)) CORRECT")
println()
