#!/usr/bin/env julia
# PURE-325 Agent 22: Test the actual parsestmt(Expr, s) path
# If cursor iteration works, the crash must be in node_to_expr processing

using WasmTarget
using JuliaSyntax

# Test: Just call parsestmt and check if it returns an Expr
# parsestmt(Expr, "1") should return the integer 1 (a leaf)
# parsestmt(Expr, "1+1") should return :(1+1)
function test_parsestmt_leaf(s::String)
    result = JuliaSyntax.parsestmt(Expr, s)
    # For leaf inputs like "1", result is just 1 (an Int)
    # Return 1 if it produced a result, 0 if error
    return Int32(1)
end

# Test: What does parsestmt(Expr, "1") return?
# It should be the integer literal 1
function test_parse_literal_value(s::String)
    result = JuliaSyntax.parsestmt(Expr, s)
    # For "1", result should be 1::Int64
    if result isa Int64
        return Int32(result)
    end
    return Int32(-1)
end

# Run native Julia first
println("=== Native Julia Ground Truth ===")
println("  parsestmt(Expr, \"1\") = ", repr(JuliaSyntax.parsestmt(Expr, "1")))
println("  parsestmt(Expr, \"42\") = ", repr(JuliaSyntax.parsestmt(Expr, "42")))
println("  parsestmt(Expr, \"1+1\") = ", repr(JuliaSyntax.parsestmt(Expr, "1+1")))
println("  parsestmt(Expr, \"x\") = ", repr(JuliaSyntax.parsestmt(Expr, "x")))
println()
println("  test_parsestmt_leaf(\"1\") = ", test_parsestmt_leaf("1"))
println("  test_parse_literal_value(\"1\") = ", test_parse_literal_value("1"))
println("  test_parse_literal_value(\"42\") = ", test_parse_literal_value("42"))

# Now let's understand node_to_expr's IR to see what it does
println("\n=== Analyzing node_to_expr IR ===")
# Find the specific method that parseargs! calls
parseargs_method = methods(JuliaSyntax.parseargs!, (Expr, LineNumberNode, JuliaSyntax.RedTreeCursor, Any, Vector{UInt8}, UInt32))
println("parseargs! methods: ", parseargs_method)

# Check what node_to_expr returns for specific inputs
println("\n=== node_to_expr on each child of '1+1' ===")
stream = JuliaSyntax.ParseStream("1+1")
JuliaSyntax.parse!(stream)
cursor = JuliaSyntax.RedTreeCursor(stream)
# Get call node
r = iterate(Iterators.reverse(cursor))
call_cursor, _ = r
println("Call node kind: ", JuliaSyntax.kind(call_cursor))
# Get source for node_to_expr
source = JuliaSyntax.SourceFile("1+1")
txtbuf = UInt8[]
for child in Iterators.reverse(call_cursor)
    k = JuliaSyntax.kind(child)
    is_t = JuliaSyntax.is_trivia(child)
    should_inc = !is_t || JuliaSyntax.is_error(child)
    println("  Child: kind=$k, is_trivia=$is_t, should_include=$should_inc, is_leaf=$(JuliaSyntax.is_leaf(child))")
end

# Compile test_parsestmt_leaf (this includes the full parsestmt path)
println("\n=== Compiling ===")
for (name, fn) in [
    ("test_parsestmt_leaf", test_parsestmt_leaf),
    ("test_parse_literal_value", test_parse_literal_value),
]
    print("  $name: ")
    try
        bytes = compile(fn, (String,))
        outpath = "WasmTarget.jl/browser/$(name).wasm"
        write(outpath, bytes)
        println("$(length(bytes)) bytes → $outpath")
    catch e
        println("COMPILE ERROR: $(sprint(showerror, e)[1:min(200, end)])")
    end
end

println("\nDone.")
