#!/usr/bin/env julia
# PURE-5001: Deeper parse investigation
#
# The full parsestmt("1+1") EXECUTES but `isa Expr` returns false.
# This script tests sub-steps to find where the issue is.

using WasmTarget
using JuliaSyntax

println("=" ^ 60)
println("PURE-5001: Deeper Parse Investigation")
println("=" ^ 60)

# Test what parsestmt actually returns
# parsestmt(Expr, "1+1") internally does:
#   1. ps = ParseStream("1+1")
#   2. parse!(ps, rule=:statement)
#   3. tree = build_tree(...)
#   4. result = to_expr(tree)
# Let's check if the problem is isa Expr or the result itself

# Test: Does parsestmt return something non-nothing?
function test_parse_not_nothing()::Int32
    result = JuliaSyntax.parsestmt(Expr, "1+1")
    return result === nothing ? Int32(0) : Int32(1)
end

# Test: What does native Julia say parsestmt returns?
println("\nNative Julia ground truth:")
native_result = JuliaSyntax.parsestmt(Expr, "1+1")
println("  parsestmt(Expr, \"1+1\") = $native_result")
println("  typeof = $(typeof(native_result))")
println("  isa Expr = $(native_result isa Expr)")
println("  isa Integer = $(native_result isa Integer)")
println("  isa Symbol = $(native_result isa Symbol)")

# Hmm, parsestmt("1+1") might return an Expr(:call, :+, 1, 1)
# But for "42" it returns just 42 (an Int)
# Let's test both

native_42 = JuliaSyntax.parsestmt(Expr, "42")
println("\n  parsestmt(Expr, \"42\") = $native_42")
println("  typeof = $(typeof(native_42))")
println("  isa Integer = $(native_42 isa Integer)")

# So for "42", the result is Integer, not Expr!
# Our test_parsestmt_full checked `isa Expr` which is WRONG for "42"
# But test_parse_returns also uses "1+1" which should be Expr

# Test: check type of result for "1+1" (should be Expr)
function test_parse_type_is_expr()::Int32
    result = JuliaSyntax.parsestmt(Expr, "1+1")
    return result isa Expr ? Int32(1) : Int32(0)
end

# Test: check if result is Any non-nothing value
function test_parse_returns_something()::Int32
    result = JuliaSyntax.parsestmt(Expr, "1+1")
    return result === nothing ? Int32(0) : Int32(1)
end

# Test: try accessing the head of the Expr
function test_parse_expr_head_is_call()::Int32
    result = JuliaSyntax.parsestmt(Expr, "1+1")
    if result isa Expr
        return result.head === :call ? Int32(1) : Int32(2)
    end
    return Int32(0)  # Not Expr
end

# Test: just return 42 parsed (should be Int)
function test_parse_42()::Int64
    result = JuliaSyntax.parsestmt(Expr, "42")
    if result isa Int64
        return result
    end
    return Int64(-1)
end

# Test: try returning number of args in "1+1" Expr
function test_parse_nargs()::Int32
    result = JuliaSyntax.parsestmt(Expr, "1+1")
    if result isa Expr
        return Int32(length(result.args))
    end
    return Int32(-1)
end

# Compile and test
include(joinpath(@__DIR__, "..", "test", "utils.jl"))

tests = [
    ("test_parse_not_nothing", test_parse_not_nothing, (), Int32(1)),
    ("test_parse_returns_something", test_parse_returns_something, (), Int32(1)),
    ("test_parse_type_is_expr", test_parse_type_is_expr, (), Int32(1)),
    ("test_parse_expr_head_is_call", test_parse_expr_head_is_call, (), Int32(1)),
    ("test_parse_42", test_parse_42, (), Int64(42)),
    ("test_parse_nargs", test_parse_nargs, (), Int32(3)),  # :+, 1, 1
]

for (name, func, argtypes, expected) in tests
    println("\n--- $name ---")
    print("  Compiling: ")
    local wasm_bytes
    try
        wasm_bytes = compile_multi([(func, argtypes)])
        println("$(length(wasm_bytes)) bytes")
    catch e
        println("COMPILE_ERROR: $(first(sprint(showerror, e), 200))")
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
        rm(tmpf, force=true)
        continue
    end

    if NODE_CMD !== nothing
        try
            actual = run_wasm(wasm_bytes, name)
            if actual == expected
                println("  CORRECT: $actual")
            else
                println("  WRONG: got $actual, expected $expected")
            end
        catch e
            emsg = sprint(showerror, e)
            println("  ERROR: $(first(emsg, 150))")
        end
    end
    rm(tmpf, force=true)
end

println("\nDone.")
