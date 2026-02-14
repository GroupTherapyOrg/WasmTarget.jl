#!/usr/bin/env julia
# PURE-325 Agent 22: Diagnose parse_julia_literal failure
# test_parse_literal_from_buf returned -999 (not Int64)

using WasmTarget
using JuliaSyntax

# Test: Does SyntaxHead construction work?
function test_syntax_head_kind()
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    k = head.kind
    # K"Integer" raw value
    return Int32(reinterpret(UInt16, k))
end

# Test: Can we compare Kind values?
function test_kind_eq()
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    k = head.kind
    if k == JuliaSyntax.K"Integer"
        return Int32(1)
    end
    return Int32(0)
end

# Test: Does SubString from textbuf work?
function test_substr_from_buf()
    txtbuf = UInt8[0x31]  # "1"
    range = UInt32(1):UInt32(1)
    # parse_julia_literal converts the range to a SubString via source access
    # Let's test the simpler path: just get the string
    s = String(txtbuf[range])
    return Int32(ncodeunits(s))
end

# Test: Does parse_julia_literal even get called with correct args?
# Use a simpler version: just check if it returns an Int
function test_literal_type()
    txtbuf = UInt8[0x31]
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    range = UInt32(1):UInt32(1)
    result = JuliaSyntax.parse_julia_literal(txtbuf, head, range)
    if result isa Integer
        return Int32(1)
    elseif result isa Symbol
        return Int32(2)
    elseif result isa Nothing
        return Int32(3)
    end
    return Int32(0)
end

# Run native Julia
println("=== Native Julia Ground Truth ===")
println("  test_syntax_head_kind() = ", test_syntax_head_kind())
println("  test_kind_eq() = ", test_kind_eq())
println("  test_substr_from_buf() = ", test_substr_from_buf())
println("  test_literal_type() = ", test_literal_type())

# Compile
println("\n=== Compiling ===")
for (name, fn) in [
    ("test_syntax_head_kind", test_syntax_head_kind),
    ("test_kind_eq", test_kind_eq),
    ("test_substr_from_buf", test_substr_from_buf),
    ("test_literal_type", test_literal_type),
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
