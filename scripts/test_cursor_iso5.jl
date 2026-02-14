#!/usr/bin/env julia
# PURE-325 Agent 22: Test parse_julia_literal directly
# The key function that converts source text to Julia values

using WasmTarget
using JuliaSyntax

# Test: parse_int_literal (the inner function)
# This does: replace(str, '_'=>"") then Base.parse(Int, str)
function test_parse_int_lit(s::String)
    result = JuliaSyntax.parse_int_literal(s)
    if result isa Int64
        return Int32(result)
    elseif result isa Int32
        return result
    end
    return Int32(-999)
end

# Test: parse_julia_literal on a textbuf with known content
# This is what _expr_leaf_val calls
function test_parse_literal_from_buf()
    # Simulate parsing "1": textbuf = [0x31], head = SyntaxHead(K"Integer", ...), range = 1:1
    txtbuf = UInt8[0x31]  # "1" in ASCII
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    range = UInt32(1):UInt32(1)
    result = JuliaSyntax.parse_julia_literal(txtbuf, head, range)
    if result isa Int64
        return Int32(result)
    end
    return Int32(-999)
end

# Test: the actual build_tree for leaf only
# parsestmt for "1" should work (it's a leaf, no parseargs!)
function test_build_tree_1()
    result = JuliaSyntax.parsestmt(Expr, "1")
    if result isa Int64
        return Int32(result)
    end
    return Int32(-999)
end

# Test: build_tree for non-leaf
# parsestmt for "1+1" exercises the full parseargs! path
function test_build_tree_1plus1()
    result = JuliaSyntax.parsestmt(Expr, "1+1")
    # For "1+1", result is Expr(:call, :+, 1, 1) which is not Int64
    # Just return 1 if it succeeds
    return Int32(1)
end

# Native Julia ground truth
println("=== Native Julia Ground Truth ===")
println("  test_parse_int_lit(\"1\") = ", test_parse_int_lit("1"))
println("  test_parse_int_lit(\"42\") = ", test_parse_int_lit("42"))
println("  test_parse_int_lit(\"0\") = ", test_parse_int_lit("0"))
println("  test_parse_literal_from_buf() = ", test_parse_literal_from_buf())
println("  test_build_tree_1() = ", test_build_tree_1())
println("  test_build_tree_1plus1() = ", test_build_tree_1plus1())

# Compile test_parse_int_lit and test_parse_literal_from_buf
println("\n=== Compiling ===")
for (name, fn, argtypes) in [
    ("test_parse_int_lit", test_parse_int_lit, (String,)),
    ("test_parse_literal_from_buf", test_parse_literal_from_buf, ()),
]
    print("  $name: ")
    try
        bytes = compile(fn, argtypes)
        outpath = "WasmTarget.jl/browser/$(name).wasm"
        write(outpath, bytes)
        println("$(length(bytes)) bytes → $outpath")
    catch e
        println("COMPILE ERROR: $(sprint(showerror, e)[1:min(300, end)])")
    end
end

println("\nDone.")
