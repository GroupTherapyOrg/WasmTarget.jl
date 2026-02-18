#!/usr/bin/env julia
# PURE-5002: Stage 1 execution — parse_to_expr wrapper
#
# PURE-5001 proved: ParseStream, parse!, build_tree(Expr) all EXECUTE CORRECTLY.
# The issue is only in parsestmt's _parse#83 wrapper (returns nothing).
# Solution: bypass _parse#83 by calling ParseStream → parse! → build_tree directly.
#
# This script:
# 1. Defines parse_to_expr(code::String) wrapper
# 2. Defines test functions that return Int32 indicators
# 3. Compiles each individually to Wasm
# 4. Tests in Node.js against native Julia ground truth
#
# NATIVE JULIA GROUND TRUTH (recorded before Wasm testing):
#   build_tree(Expr, ParseStream("1+1")) → Expr(:call, :+, 1, 1)
#     - isa Expr = true, head = :call, nargs = 3
#   build_tree(Expr, ParseStream("42")) → 42
#     - isa Int64 = true, value = 42
#   build_tree(Expr, ParseStream("sin(1.0)")) → Expr(:call, :sin, 1.0)
#     - isa Expr = true, head = :call, nargs = 2

using WasmTarget
using JuliaSyntax

println("=" ^ 60)
println("PURE-5002: Stage 1 — parse_to_expr wrapper tests")
println("=" ^ 60)

include(joinpath(@__DIR__, "..", "test", "utils.jl"))

# ═══════════════════════════════════════════════════════════════
# The parse_to_expr wrapper — bypasses _parse#83
# ═══════════════════════════════════════════════════════════════

# Test 1: parse "1+1" — result is not nothing
# Native ground truth: build_tree returns Expr(:call, :+, 1, 1), so NOT nothing → 1
function test_parse_1plus1_not_nothing()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

# Test 2: parse "1+1" — result is an Expr
# Native ground truth: result isa Expr = true → 1
function test_parse_1plus1_is_expr()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Expr ? Int32(1) : Int32(0)
end

# Test 3: parse "1+1" — Expr has 3 args (:+, 1, 1)
# Native ground truth: length(result.args) = 3
function test_parse_1plus1_nargs()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Expr ? Int32(length(result.args)) : Int32(-1)
end

# Test 4: parse "1+1" — head is :call
# Native ground truth: result.head == :call → 1
function test_parse_1plus1_is_call()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return (result isa Expr && result.head === :call) ? Int32(1) : Int32(0)
end

# Test 5: parse "42" — result is Int64 (not Expr, not nothing)
# Native ground truth: build_tree("42") = 42 (Int64), isa Int64 = true → 1
function test_parse_42_is_int()::Int32
    ps = JuliaSyntax.ParseStream("42")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Int64 ? Int32(1) : Int32(0)
end

# Test 6: parse "42" — value equals 42
# Native ground truth: result == 42 → 1
function test_parse_42_value()::Int32
    ps = JuliaSyntax.ParseStream("42")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return (result isa Int64 && result == 42) ? Int32(1) : Int32(0)
end

# Test 7: parse "sin(1.0)" — result is an Expr with head :call
# Native ground truth: Expr(:call, :sin, 1.0), isa Expr = true, head = :call → 1
function test_parse_sin_is_call()::Int32
    ps = JuliaSyntax.ParseStream("sin(1.0)")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return (result isa Expr && result.head === :call) ? Int32(1) : Int32(0)
end

# Test 8: parse "sin(1.0)" — has 2 args (:sin, 1.0)
# Native ground truth: length(result.args) = 2
function test_parse_sin_nargs()::Int32
    ps = JuliaSyntax.ParseStream("sin(1.0)")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Expr ? Int32(length(result.args)) : Int32(-1)
end

# Test 9: parse "f(x) = x + 1" — result is Expr with head :(=)
# Native ground truth: isa Expr = true, head = :(=) → 1
function test_parse_fundef_is_eq()::Int32
    ps = JuliaSyntax.ParseStream("f(x) = x + 1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return (result isa Expr && result.head === :(=)) ? Int32(1) : Int32(0)
end

# Test 10: parse "f(x) = x + 1" — has 2 args (lhs, rhs)
# Native ground truth: length(result.args) = 2
function test_parse_fundef_nargs()::Int32
    ps = JuliaSyntax.ParseStream("f(x) = x + 1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Expr ? Int32(length(result.args)) : Int32(-1)
end

# ═══════════════════════════════════════════════════════════════
# Compile and test each individually
# ═══════════════════════════════════════════════════════════════

tests = [
    ("test_parse_1plus1_not_nothing", test_parse_1plus1_not_nothing, (), Int32(1)),
    ("test_parse_1plus1_is_expr",     test_parse_1plus1_is_expr,     (), Int32(1)),
    ("test_parse_1plus1_nargs",       test_parse_1plus1_nargs,       (), Int32(3)),
    ("test_parse_1plus1_is_call",     test_parse_1plus1_is_call,     (), Int32(1)),
    ("test_parse_42_is_int",          test_parse_42_is_int,          (), Int32(0)),  # NOTE: may be Int64 literal
    ("test_parse_42_value",           test_parse_42_value,           (), Int32(0)),  # NOTE: literal path unclear
    ("test_parse_sin_is_call",        test_parse_sin_is_call,        (), Int32(1)),
    ("test_parse_sin_nargs",          test_parse_sin_nargs,          (), Int32(2)),
    ("test_parse_fundef_is_eq",       test_parse_fundef_is_eq,       (), Int32(1)),
    ("test_parse_fundef_nargs",       test_parse_fundef_nargs,       (), Int32(2)),
]

# Wait — first verify native Julia behavior for all tests
println("\n--- Native Julia Ground Truth ---")
for (name, func, _, _) in tests
    try
        native = func()
        println("  $name: native = $native")
    catch e
        println("  $name: ERROR — $(first(sprint(showerror, e), 100))")
    end
end

# Now update expected values based on native results
# (The expected values above are educated guesses; native execution is the oracle)
println()

results = Dict{String,String}()

for (name, func, argtypes, _expected) in tests
    # Get native ground truth
    local expected
    try
        expected = func()
    catch e
        println("\n--- $name ---")
        println("  NATIVE ERROR: $(first(sprint(showerror, e), 100))")
        results[name] = "NATIVE_ERROR"
        continue
    end

    println("\n--- $name ---")
    println("  Native: $expected")

    # Compile
    print("  Compiling: ")
    local wasm_bytes
    try
        wasm_bytes = compile_multi([(func, argtypes)])
        println("$(length(wasm_bytes)) bytes")
    catch e
        println("COMPILE_ERROR: $(first(sprint(showerror, e), 200))")
        results[name] = "COMPILE_ERROR"
        continue
    end

    # Validate
    tmpf = tempname() * ".wasm"
    write(tmpf, wasm_bytes)
    print("  Validate: ")
    valid = try
        run(`wasm-tools validate --features=gc $tmpf`)
        println("VALIDATES")
        true
    catch
        valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
        println("VALIDATE_ERROR: $(first(valerr, 200))")
        false
    end

    if !valid
        results[name] = "VALIDATE_ERROR"
        rm(tmpf, force=true)
        continue
    end

    # Execute in Node.js
    if NODE_CMD !== nothing
        print("  Execute: ")
        try
            actual = run_wasm(wasm_bytes, name)
            if actual == expected
                println("CORRECT (native=$expected, wasm=$actual)")
                results[name] = "CORRECT"
            else
                println("WRONG (native=$expected, wasm=$actual)")
                results[name] = "WRONG"
            end
        catch e
            emsg = sprint(showerror, e)
            if contains(emsg, "unreachable") || contains(emsg, "trap")
                println("TRAP")
                results[name] = "TRAP"
            elseif contains(emsg, "timeout") || contains(emsg, "Timed out")
                println("HANG")
                results[name] = "HANG"
            else
                println("ERROR: $(first(emsg, 150))")
                results[name] = "ERROR"
            end
        end
    else
        results[name] = "NO_NODE"
    end
    rm(tmpf, force=true)
end

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
println("\n" * "=" ^ 60)
println("PURE-5002: Stage 1 Parse Results")
println("=" ^ 60)
println("| Test | Result |")
println("|------|--------|")
for (name, _, _, _) in tests
    result = get(results, name, "UNKNOWN")
    println("| $name | $result |")
end

correct = count(v -> v == "CORRECT", values(results))
total = length(tests)
println("\n$correct/$total CORRECT")
println()
