#!/usr/bin/env julia
# Batch isolation compilation for PURE-325
# Agent 28: Compile individual test functions for build_tree phase

using WasmTarget, JuliaSyntax

const BROWSER_DIR = @__DIR__

# Helper to compile and write a test function
function compile_test(name::String, f, argtypes::Tuple)
    println("Compiling $name...")
    try
        bytes = compile(f, argtypes)
        outf = joinpath(BROWSER_DIR, "test_$(name).wasm")
        write(outf, bytes)
        # Validate
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(`wasm-tools validate --features=gc $tmpf`)
        nfuncs = 0
        try
            nfuncs = parse(Int, strip(read(`wasm-tools print $tmpf`, String) |> x -> count("(func ", x) |> string))
        catch
        end
        println("  $name: VALIDATES, $(length(bytes)) bytes")
        return true
    catch e
        println("  $name: COMPILE FAIL — $(sprint(showerror, e))")
        return false
    end
end

# ============================================================================
# Test 1: test_reverse_count — count children of call node for "1+1"
# ============================================================================
function test_reverse_count(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    # Navigate to first child (call node)
    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    call_cursor = r1[1]

    count = Int32(0)
    r = iterate(Iterators.reverse(call_cursor))
    while r !== nothing
        count += Int32(1)
        r = iterate(Iterators.reverse(call_cursor), r[2])
    end
    return count
end
println("Native: test_reverse_count(\"1+1\") = $(test_reverse_count("1+1"))")
compile_test("reverse_count", test_reverse_count, (String,))

# ============================================================================
# Test 2: test_filter_count — count nontrivia children through Iterators.filter
# ============================================================================
function test_filter_count(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    # Navigate to first child
    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    call_cursor = r1[1]

    count = Int32(0)
    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(call_cursor))
    r = iterate(itr)
    while r !== nothing
        count += Int32(1)
        r = iterate(itr, r[2])
    end
    return count
end
println("Native: test_filter_count(\"1+1\") = $(test_filter_count("1+1"))")
compile_test("filter_count", test_filter_count, (String,))

# ============================================================================
# Test 3: test_child_kind — return kind of first nontrivia child
# ============================================================================
function test_child_kind(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    # Navigate to first child
    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    call_cursor = r1[1]

    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(call_cursor))
    r = iterate(itr)
    r === nothing && return Int32(-2)
    child = r[1]

    k = JuliaSyntax.kind(child)
    return Int32(reinterpret(UInt16, k))
end
println("Native: test_child_kind(\"1+1\") = $(test_child_kind("1+1")) (K\"Integer\" = $(reinterpret(UInt16, JuliaSyntax.K"Integer")))")
compile_test("child_kind", test_child_kind, (String,))

# ============================================================================
# Test 4: test_leaf_val — get the leaf value for first child of "1+1"
# ============================================================================
function test_leaf_val(s::String)::Int64
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int64(-1)
    call_cursor = r1[1]

    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(call_cursor))
    r = iterate(itr)
    r === nothing && return Int64(-2)
    child = r[1]

    # Call parse_julia_literal (same as _expr_leaf_val)
    txtbuf = Vector{UInt8}(s)
    val = JuliaSyntax.parse_julia_literal(txtbuf, JuliaSyntax.head(child), JuliaSyntax.byte_range(child))
    val isa Int64 && return val
    return Int64(-3)
end
println("Native: test_leaf_val(\"1+1\") = $(test_leaf_val("1+1"))")
compile_test("leaf_val", test_leaf_val, (String,))

# ============================================================================
# Test 5: test_untokenize — untokenize the head of the call node
# ============================================================================
function test_untokenize_len(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    call_cursor = r1[1]

    nodehead = JuliaSyntax.head(call_cursor)
    headstr = JuliaSyntax.untokenize(nodehead, include_flag_suff=false)
    headstr === nothing && return Int32(-2)
    return Int32(length(headstr))
end
println("Native: test_untokenize_len(\"1+1\") = $(test_untokenize_len("1+1"))")
compile_test("untokenize_len", test_untokenize_len, (String,))

# ============================================================================
# Test 6: test_node_to_expr_leaf — call node_to_expr on a leaf child
# This is the exact crash path!
# ============================================================================
function test_node_to_expr_leaf(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    source = JuliaSyntax.SourceFile(s)
    txtbuf = Vector{UInt8}(s)

    # Navigate to first child (call node)
    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    call_cursor = r1[1]

    # Get first nontrivia child
    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(call_cursor))
    r = iterate(itr)
    r === nothing && return Int32(-2)
    child = r[1]

    # Call node_to_expr on it — this is the exact path that crashes!
    expr = JuliaSyntax.node_to_expr(child, source, txtbuf, UInt32(0))
    expr === nothing && return Int32(-3)
    return Int32(1)
end
println("Native: test_node_to_expr_leaf(\"1+1\") = $(test_node_to_expr_leaf("1+1"))")
compile_test("node_to_expr_leaf", test_node_to_expr_leaf, (String,))

println("\n=== All compilations done ===")
