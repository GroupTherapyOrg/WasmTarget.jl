#!/usr/bin/env julia
# PURE-325 Agent 22: Isolation test of cursor iteration
# Goal: find exactly which step breaks when iterating children

using WasmTarget
using JuliaSyntax

# Test 1: Just get the output length after parsing "1+1"
# Native Julia should return the length of the parser output vector
function test_output_length(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return Int32(length(stream.output))
end

# Test 2: Get the top-level node's node_span (number of children)
function test_top_node_span(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.GreenTreeCursor(stream)
    node = cursor.parser_output[cursor.position]
    # node_span is the number of child nodes for non-terminal nodes
    return Int32(node.node_span_or_orig_kind)
end

# Test 3: Get just the first reverse iteration child's position
# This tests the initial state calculation of Reverse iteration
function test_first_child_position(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.GreenTreeCursor(stream)
    rev = Iterators.reverse(cursor)
    r = iterate(rev)
    if r === nothing
        return Int32(-1)
    end
    child, state = r
    return Int32(child.position)
end

# Test 4: Count children via iteration
function test_child_count(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.GreenTreeCursor(stream)
    count = Int32(0)
    for child in Iterators.reverse(cursor)
        count += Int32(1)
    end
    return count
end

# Run native Julia first to get ground truth
println("=== Native Julia Ground Truth ===")
for input in ["1", "1+1", "x"]
    println("  test_output_length(\"$input\") = ", test_output_length(input))
end
for input in ["1", "1+1", "x"]
    println("  test_top_node_span(\"$input\") = ", test_top_node_span(input))
end
for input in ["1", "1+1", "x"]
    println("  test_first_child_position(\"$input\") = ", test_first_child_position(input))
end
for input in ["1", "1+1", "x"]
    println("  test_child_count(\"$input\") = ", test_child_count(input))
end

# Compile each function individually
println("\n=== Compiling ===")
for (name, fn) in [
    ("test_output_length", test_output_length),
    ("test_top_node_span", test_top_node_span),
    ("test_first_child_position", test_first_child_position),
    ("test_child_count", test_child_count),
]
    print("  $name: ")
    try
        bytes = compile(fn, (String,))
        outpath = "WasmTarget.jl/browser/$(name).wasm"
        write(outpath, bytes)
        println("$(length(bytes)) bytes → $outpath")
    catch e
        println("COMPILE ERROR: $e")
    end
end

println("\nDone. Test with Node.js next.")
