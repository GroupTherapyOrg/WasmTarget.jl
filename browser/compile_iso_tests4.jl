#!/usr/bin/env julia
# PURE-325 Agent 28: Phase 4 — test within parsestmt module context
# Instead of compiling NEW test functions, add a DIAGNOSTIC EXPORT to parsestmt
# that calls node_to_expr on a specific child and returns a diagnostic code

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
        nfuncs = count("(func ", read(`wasm-tools print $tmpf`, String))
        println("  $name: VALIDATES, $(length(bytes)) bytes, $nfuncs funcs")
        return true
    catch e
        println("  $name: FAIL — $(sprint(showerror, e)[1:min(200,end)])")
        return false
    end
end

# ============================================================================
# Key insight: The full parsestmt.wasm has copyto_unaliased! compiled.
# When I compile a SMALLER isolation test, it gets STUBBED.
# So I need to test within a module that INCLUDES copyto_unaliased!.
#
# Instead of compiling standalone, I'll use compile_multi to include
# parse_expr_string + a diagnostic function, so all deps are included.
# ============================================================================

# ============================================================================
# Test K: compile_multi with parse_expr_string AND a diagnostic
# The diagnostic navigates to child 1 and calls parse_julia_literal
# ============================================================================

function diag_child1_kind(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    # Navigate: toplevel → first child (call node)
    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    top_child = r1[1]

    # Get the first nontrivia child of the call/toplevel node
    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(top_child))
    r = iterate(itr)
    r === nothing && return Int32(-2)
    child = r[1]

    return Int32(reinterpret(UInt16, JuliaSyntax.kind(child)))
end

function diag_should_include(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    top_child = r1[1]

    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(top_child))
    r = iterate(itr)
    r === nothing && return Int32(-2)
    child = r[1]

    # Check should_include_node on the child (same check node_to_expr does)
    inc = JuliaSyntax.should_include_node(child)
    return inc ? Int32(1) : Int32(0)
end

function diag_is_leaf(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)

    r1 = iterate(Iterators.reverse(cursor))
    r1 === nothing && return Int32(-1)
    top_child = r1[1]

    itr = Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(top_child))
    r = iterate(itr)
    r === nothing && return Int32(-2)
    child = r[1]

    return JuliaSyntax.is_leaf(child) ? Int32(1) : Int32(0)
end

# ============================================================================
# Use compile_multi to compile all diagnostics together with parse_expr_string
# This ensures ALL dependencies (including copyto_unaliased!) are included
# ============================================================================

parse_expr_string(s::String) = JuliaSyntax.parsestmt(Expr, s)

println("Native: diag_child1_kind(\"1+1\") = $(diag_child1_kind("1+1"))")
println("Native: diag_should_include(\"1+1\") = $(diag_should_include("1+1"))")
println("Native: diag_is_leaf(\"1+1\") = $(diag_is_leaf("1+1"))")

println("\nCompiling multi-module with diagnostics...")
try
    bytes = compile_multi([
        (parse_expr_string, (String,)),
        (diag_child1_kind, (String,)),
        (diag_should_include, (String,)),
        (diag_is_leaf, (String,)),
    ])
    outf = joinpath(BROWSER_DIR, "test_parsestmt_diag.wasm")
    write(outf, bytes)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    run(`wasm-tools validate --features=gc $tmpf`)
    nfuncs = count("(func ", read(`wasm-tools print $tmpf`, String))
    println("  parsestmt_diag: VALIDATES, $(length(bytes)) bytes, $nfuncs funcs")
catch e
    println("  parsestmt_diag: FAIL — $(sprint(showerror, e)[1:min(200,end)])")
end

println("\n=== Phase 4 compilations done ===")
