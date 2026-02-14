#!/usr/bin/env julia
# PURE-325 Agent 28: Phase 3 — narrow parse_julia_literal crash
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
        println("  $name: FAIL — $(sprint(showerror, e)[1:min(200, end)])")
        return false
    end
end

# ============================================================================
# Test F: parse_int_literal directly (what agent 27 tested — should be CORRECT)
# ============================================================================
function test_pil_simple(s::String)::Int64
    # parse_int_literal takes a String and returns Union{Int128, Int64, BigInt}
    val = JuliaSyntax.parse_int_literal(s)
    val isa Int64 && return val
    return Int64(-99)
end
println("Native: test_pil_simple(\"1\") = $(test_pil_simple("1"))")
compile_test("pil_simple", test_pil_simple, (String,))

# ============================================================================
# Test G: parse_julia_literal with SyntaxHead(K"Integer", 0)
# This is the SIMPLEST parse_julia_literal call — K"Integer" branch
# The function itself has many branches but for K"Integer" it just calls parse_int_literal
# ============================================================================
function test_pjl_integer(s::String)::Int64
    txtbuf = Vector{UInt8}(s)
    h = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", UInt16(0))
    r = UInt32(1):UInt32(UInt32(length(s)))
    val = JuliaSyntax.parse_julia_literal(txtbuf, h, r)
    val isa Int64 && return val
    return Int64(-99)
end
println("Native: test_pjl_integer(\"42\") = $(test_pjl_integer("42"))")
compile_test("pjl_integer", test_pjl_integer, (String,))

# ============================================================================
# Test H: Just check if parse_julia_literal RETURNS (without checking the value)
# Return 1 if it returns anything, 0 if it returns nothing
# ============================================================================
function test_pjl_returns(s::String)::Int32
    txtbuf = Vector{UInt8}(s)
    h = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", UInt16(0))
    r = UInt32(1):UInt32(UInt32(length(s)))
    val = JuliaSyntax.parse_julia_literal(txtbuf, h, r)
    return Int32(1)  # Just return 1 if it doesn't crash
end
println("Native: test_pjl_returns(\"1\") = $(test_pjl_returns("1"))")
compile_test("pjl_returns", test_pjl_returns, (String,))

# ============================================================================
# Test I: The exact path parse_julia_literal takes for K"Integer":
#   1. val_str = String(txtbuf[srcrange])
#   2. check: kind == K"Integer" → return parse_int_literal(val_str)
# Let me split these: first test String(txtbuf[range])
# ============================================================================
function test_string_from_txtbuf(s::String)::Int32
    txtbuf = Vector{UInt8}(s)
    val_str = String(txtbuf[UInt32(1):UInt32(UInt32(length(s)))])
    return Int32(length(val_str))
end
println("Native: test_string_from_txtbuf(\"42\") = $(test_string_from_txtbuf("42"))")
compile_test("string_from_txtbuf", test_string_from_txtbuf, (String,))

# ============================================================================
# Test J: String(Vector{UInt8}) → parse_int_literal chain
# ============================================================================
function test_string_then_parse(s::String)::Int64
    txtbuf = Vector{UInt8}(s)
    val_str = String(txtbuf[UInt32(1):UInt32(UInt32(length(s)))])
    val = JuliaSyntax.parse_int_literal(val_str)
    val isa Int64 && return val
    return Int64(-99)
end
println("Native: test_string_then_parse(\"42\") = $(test_string_then_parse("42"))")
compile_test("string_then_parse", test_string_then_parse, (String,))

println("\n=== Phase 3 compilations done ===")
