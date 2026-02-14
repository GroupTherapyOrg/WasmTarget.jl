#!/usr/bin/env julia
# PURE-325 Agent 22: Test SECOND level cursor iteration (call node's children)

using WasmTarget
using JuliaSyntax

# Test 5: Get the call node's child count (iterate SECOND level)
function test_call_child_count(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.GreenTreeCursor(stream)
    rev = Iterators.reverse(cursor)
    r = iterate(rev)
    r === nothing && return Int32(-1)
    call_cursor, _ = r
    count = Int32(0)
    for child in Iterators.reverse(call_cursor)
        count += Int32(1)
    end
    return count
end

# Test 6: RedTreeCursor iteration second level
function test_red_child_count(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    rev = Iterators.reverse(cursor)
    r = iterate(rev)
    r === nothing && return Int32(-1)
    call_cursor, _ = r
    count = Int32(0)
    rev2 = Iterators.reverse(call_cursor)
    r2 = iterate(rev2)
    while r2 !== nothing
        count += Int32(1)
        _, state2 = r2
        r2 = iterate(rev2, state2)
    end
    return count
end

# Test 7: Red + filter (reverse_nontrivia_children equivalent)
function test_red_nontrivia_count(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    rev = Iterators.reverse(cursor)
    r = iterate(rev)
    r === nothing && return Int32(-1)
    call_cursor, _ = r
    count = Int32(0)
    # This is what parseargs! uses: Iterators.filter(should_include_node, Iterators.reverse(cursor))
    for child in Iterators.filter(c -> !JuliaSyntax.is_trivia(c) || JuliaSyntax.is_error(c), Iterators.reverse(call_cursor))
        count += Int32(1)
    end
    return count
end

# Test 8: Just get first child's byte_span (scalar field access on child cursor)
function test_first_child_span(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.GreenTreeCursor(stream)
    rev = Iterators.reverse(cursor)
    r = iterate(rev)
    r === nothing && return Int32(-1)
    call_cursor, _ = r
    rev2 = Iterators.reverse(call_cursor)
    r2 = iterate(rev2)
    r2 === nothing && return Int32(-2)
    child, _ = r2
    node = child.parser_output[child.position]
    return Int32(node.byte_span)
end

# Run native Julia first
println("=== Native Julia Ground Truth ===")
for input in ["1+1", "x+y", "(1)"]
    println("  test_call_child_count(\"$input\") = ", test_call_child_count(input))
end
for input in ["1+1", "x+y", "(1)"]
    println("  test_red_child_count(\"$input\") = ", test_red_child_count(input))
end
for input in ["1+1"]
    println("  test_red_nontrivia_count(\"$input\") = ", test_red_nontrivia_count(input))
    println("  test_first_child_span(\"$input\") = ", test_first_child_span(input))
end
println("  test_red_nontrivia_count(\"(1)\") = ", test_red_nontrivia_count("(1)"))

# Compile
println("\n=== Compiling ===")
for (name, fn) in [
    ("test_call_child_count", test_call_child_count),
    ("test_red_child_count", test_red_child_count),
    ("test_red_nontrivia_count", test_red_nontrivia_count),
    ("test_first_child_span", test_first_child_span),
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
