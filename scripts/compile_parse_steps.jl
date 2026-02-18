#!/usr/bin/env julia
# PURE-5001: Test parse subsystem step by step
#
# parsestmt returns nothing in Wasm. parse! works.
# The issue is between parse! completing and getting a result.
# parsestmt = _parse which does: ParseStream → parse! → build_tree → extract result

using WasmTarget
using JuliaSyntax

println("=" ^ 60)
println("PURE-5001: Parse Steps Investigation")
println("=" ^ 60)

# Native ground truth
println("\nNative Julia ground truth:")
native = JuliaSyntax.parsestmt(Expr, "1+1")
println("  parsestmt(Expr, \"1+1\") = $native")
println("  typeof = $(typeof(native))")
native42 = JuliaSyntax.parsestmt(Expr, "42")
println("  parsestmt(Expr, \"42\") = $native42")
println("  typeof = $(typeof(native42))")

# Now test what we can compile
include(joinpath(@__DIR__, "..", "test", "utils.jl"))

# Test: Does build_tree(Expr, ps) return non-nothing?
function test_build_tree_expr()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

# Test: Is build_tree(Expr, ps) result an Expr?
function test_build_tree_is_expr()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Expr ? Int32(1) : Int32(0)
end

# Test: Does parse! + build_tree work for "42"?
function test_build_tree_42()::Int32
    ps = JuliaSyntax.ParseStream("42")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

# Test: Is build_tree("42") result an Int?
function test_build_tree_42_is_int()::Int32
    ps = JuliaSyntax.ParseStream("42")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Int64 ? Int32(1) : Int32(0)
end

# Test: parsestmt "42" returns non-nothing?
function test_parsestmt_42_not_nothing()::Int32
    result = JuliaSyntax.parsestmt(Expr, "42")
    return result === nothing ? Int32(0) : Int32(1)
end

# Test: parsestmt "1+1" returns non-nothing?
function test_parsestmt_1plus1_not_nothing()::Int32
    result = JuliaSyntax.parsestmt(Expr, "1+1")
    return result === nothing ? Int32(0) : Int32(1)
end

tests = [
    ("test_build_tree_expr", test_build_tree_expr, (), Int32(1)),
    ("test_build_tree_is_expr", test_build_tree_is_expr, (), Int32(1)),
    ("test_build_tree_42", test_build_tree_42, (), Int32(1)),
    ("test_build_tree_42_is_int", test_build_tree_42_is_int, (), Int32(1)),
    ("test_parsestmt_42_not_nothing", test_parsestmt_42_not_nothing, (), Int32(1)),
    ("test_parsestmt_1plus1_not_nothing", test_parsestmt_1plus1_not_nothing, (), Int32(1)),
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
            if contains(emsg, "unreachable")
                println("  TRAP (unreachable)")
            else
                println("  ERROR: $(first(emsg, 150))")
            end
        end
    end
    rm(tmpf, force=true)
end

println("\nDone.")
