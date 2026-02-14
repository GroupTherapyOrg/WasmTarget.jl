#!/usr/bin/env julia
# PURE-325 Agent 28: Phase 2 — narrow the leaf_val crash
using WasmTarget, JuliaSyntax

const BROWSER_DIR = @__DIR__

function compile_test(name::String, f, argtypes::Tuple)
    println("Compiling $name...")
    try
        bytes = compile(f, argtypes)
        outf = joinpath(BROWSER_DIR, "test_$(name).wasm")
        write(outf, bytes)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(`wasm-tools validate --features=gc $tmpf`)
        println("  $name: VALIDATES, $(length(bytes)) bytes")
        return true
    catch e
        println("  $name: COMPILE FAIL — $(sprint(showerror, e))")
        return false
    end
end

# ============================================================================
# Test A: Get byte_range of first nontrivia child (does cursor state work?)
# ============================================================================
function test_byte_range_first(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    call_cursor = r1[1]

    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(call_cursor))
    r = iterate(itr)
    r === nothing && return Int32(-2)
    child = r[1]

    br = JuliaSyntax.byte_range(child)
    return Int32(first(br))  # Should be 1 for the first "1" in "1+1"
end
println("Native: test_byte_range_first(\"1+1\") = $(test_byte_range_first("1+1"))")
compile_test("byte_range_first", test_byte_range_first, (String,))

# ============================================================================
# Test B: Get head of first nontrivia child as raw UInt16
# ============================================================================
function test_head_raw(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    call_cursor = r1[1]

    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(call_cursor))
    r = iterate(itr)
    r === nothing && return Int32(-2)
    child = r[1]

    h = JuliaSyntax.head(child)
    # SyntaxHead has .kind_val and .flags fields
    k = JuliaSyntax.kind(h)
    return Int32(reinterpret(UInt16, k))
end
println("Native: test_head_raw(\"1+1\") = $(test_head_raw("1+1"))")
compile_test("head_raw", test_head_raw, (String,))

# ============================================================================
# Test C: Call parse_julia_literal with DIRECT args (not from cursor)
# This tests if the function works when given known-good inputs
# ============================================================================
function test_pjl_direct(s::String)::Int64
    txtbuf = Vector{UInt8}(s)
    # K"Integer" = Kind(44), with no flags
    h = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", UInt16(0))
    val = JuliaSyntax.parse_julia_literal(txtbuf, h, UInt32(1):UInt32(1))
    val isa Int64 && return val
    return Int64(-99)
end
println("Native: test_pjl_direct(\"1\") = $(test_pjl_direct("1"))")
compile_test("pjl_direct", test_pjl_direct, (String,))

# ============================================================================
# Test D: leaf_val but WITHOUT the isa check — just call parse_julia_literal
# and return 1 if it doesn't crash, -1 if it returns nothing
# ============================================================================
function test_leaf_val_no_isa(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    call_cursor = r1[1]

    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(call_cursor))
    r = iterate(itr)
    r === nothing && return Int32(-2)
    child = r[1]

    txtbuf = Vector{UInt8}(s)
    h = JuliaSyntax.head(child)
    br = JuliaSyntax.byte_range(child)

    # Just call parse_julia_literal — don't check isa
    val = JuliaSyntax.parse_julia_literal(txtbuf, h, br)
    val === nothing && return Int32(-3)
    return Int32(1)
end
println("Native: test_leaf_val_no_isa(\"1+1\") = $(test_leaf_val_no_isa("1+1"))")
compile_test("leaf_val_no_isa", test_leaf_val_no_isa, (String,))

# ============================================================================
# Test E: leaf_val with byte_range shifted by txtbuf_offset
# The actual path uses `byte_range(cursor) .+ txtbuf_offset` where offset=0
# ============================================================================
function test_leaf_val_offset(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    call_cursor = r1[1]

    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(call_cursor))
    r = iterate(itr)
    r === nothing && return Int32(-2)
    child = r[1]

    txtbuf = Vector{UInt8}(s)
    h = JuliaSyntax.head(child)
    br = JuliaSyntax.byte_range(child) .+ UInt32(0)  # This is the actual node_to_expr path

    val = JuliaSyntax.parse_julia_literal(txtbuf, h, br)
    val === nothing && return Int32(-3)
    return Int32(1)
end
println("Native: test_leaf_val_offset(\"1+1\") = $(test_leaf_val_offset("1+1"))")
compile_test("leaf_val_offset", test_leaf_val_offset, (String,))

println("\n=== Phase 2 compilations done ===")
