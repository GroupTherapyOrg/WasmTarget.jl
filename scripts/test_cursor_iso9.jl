#!/usr/bin/env julia
# PURE-325 Agent 22: Narrow to the exact bug
# is_identifier(K"Integer") should be false but might be true in Wasm

using WasmTarget
using JuliaSyntax

# Test: is_identifier on various kinds (runtime)
function test_is_identifier_integer()
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    k = JuliaSyntax.kind(head)
    return Int32(JuliaSyntax.is_identifier(k) ? 1 : 0)
end

function test_is_operator_integer()
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    k = JuliaSyntax.kind(head)
    return Int32(JuliaSyntax.is_operator(k) ? 1 : 0)
end

function test_is_keyword_integer()
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    k = JuliaSyntax.kind(head)
    return Int32(JuliaSyntax.is_keyword(k) ? 1 : 0)
end

# Test: Which exact check matches in parse_julia_literal?
# Break it into pieces. First half of checks:
function test_first_half_checks()
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    k = JuliaSyntax.kind(head)
    # First checks (should all be false for Integer)
    k == JuliaSyntax.K"Float" && return Int32(1)
    k == JuliaSyntax.K"Float32" && return Int32(2)
    k == JuliaSyntax.K"Char" && return Int32(3)
    k in JuliaSyntax.KSet"String CmdString" && return Int32(4)
    k == JuliaSyntax.K"Bool" && return Int32(5)
    # Past first half — return 0 (none matched)
    return Int32(0)
end

# Second half of checks:
function test_second_half_checks()
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    k = JuliaSyntax.kind(head)
    # Second half (after String(txtbuf[srcrange]) in real code)
    k == JuliaSyntax.K"Integer" && return Int32(10)
    k in JuliaSyntax.KSet"BinInt OctInt HexInt" && return Int32(11)
    JuliaSyntax.is_identifier(k) && return Int32(12)
    JuliaSyntax.is_operator(k) && return Int32(13)
    k == JuliaSyntax.K"error" && return Int32(14)
    JuliaSyntax.is_keyword(k) && return Int32(16)
    return Int32(17)
end

# Native Julia
println("=== Native Julia Ground Truth ===")
println("  test_is_identifier_integer() = ", test_is_identifier_integer())
println("  test_is_operator_integer() = ", test_is_operator_integer())
println("  test_is_keyword_integer() = ", test_is_keyword_integer())
println("  test_first_half_checks() = ", test_first_half_checks())
println("  test_second_half_checks() = ", test_second_half_checks())

# Compile
println("\n=== Compiling ===")
for (name, fn) in [
    ("test_is_identifier_integer", test_is_identifier_integer),
    ("test_is_operator_integer", test_is_operator_integer),
    ("test_is_keyword_integer", test_is_keyword_integer),
    ("test_first_half_checks", test_first_half_checks),
    ("test_second_half_checks", test_second_half_checks),
]
    print("  $name: ")
    try
        bytes = compile(fn, ())
        outpath = "WasmTarget.jl/browser/$(name).wasm"
        write(outpath, bytes)
        println("$(length(bytes)) bytes → $outpath")
    catch e
        println("COMPILE ERROR: $(sprint(showerror, e)[1:min(300, end)])")
    end
end

println("\nDone.")
