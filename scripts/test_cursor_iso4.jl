#!/usr/bin/env julia
# PURE-325 Agent 22: Test parse_julia_literal / _expr_leaf_val in isolation
# The crash is inside node_to_expr processing, not in cursor iteration.

using WasmTarget
using JuliaSyntax

# Test: parse_int_literal (the core integer parsing function)
# parse_int_literal does: replace(str, '_'=>"") then Base.parse(Int, str)
function test_parse_int(s::String)
    result = JuliaSyntax.parse_int_literal(s)
    if result isa Int64
        return Int32(result)
    end
    return Int32(-1)
end

# Test: _expr_leaf_val on a known-good cursor
# This is what node_to_expr calls for leaf nodes
function test_leaf_val(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    # For "1": toplevel → Integer (only child)
    rev = Iterators.reverse(cursor)
    r = iterate(rev)
    r === nothing && return Int32(-1)
    child, _ = r
    # Now test is_leaf
    if JuliaSyntax.is_leaf(child)
        return Int32(1)
    end
    return Int32(0)
end

# Test: Full leaf val extraction
function test_leaf_val_extract(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    rev = Iterators.reverse(cursor)
    r = iterate(rev)
    r === nothing && return Int32(-1)
    child, _ = r
    # Call the actual function that node_to_expr calls
    txtbuf = UInt8[]
    val = JuliaSyntax._expr_leaf_val(child, txtbuf, UInt32(0))
    if val isa Int64
        return Int32(val)
    elseif val isa Symbol
        return Int32(99) # Symbol marker
    end
    return Int32(-2)
end

# Test: build_tree with just toplevel → leaf (no parseargs!)
function test_build_tree_leaf(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    source = JuliaSyntax.SourceFile(s)
    txtbuf = UInt8[]
    # Call build_tree manually
    result = JuliaSyntax.build_tree(Expr, stream; filename="none")
    if result isa Int64
        return Int32(result)
    end
    return Int32(-1)
end

# Run native Julia first
println("=== Native Julia Ground Truth ===")
println("  test_parse_int(\"1\") = ", test_parse_int("1"))
println("  test_parse_int(\"42\") = ", test_parse_int("42"))
println("  test_leaf_val(\"1\") = ", test_leaf_val("1"))
println("  test_leaf_val_extract(\"1\") = ", test_leaf_val_extract("1"))
println("  test_leaf_val_extract(\"42\") = ", test_leaf_val_extract("42"))
println("  test_build_tree_leaf(\"1\") = ", test_build_tree_leaf("1"))

# Compile each individually
println("\n=== Compiling ===")
for (name, fn) in [
    ("test_parse_int", test_parse_int),
    ("test_leaf_val", test_leaf_val),
    ("test_leaf_val_extract", test_leaf_val_extract),
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
