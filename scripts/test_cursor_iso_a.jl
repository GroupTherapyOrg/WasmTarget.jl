#!/usr/bin/env julia
# PURE-325 Agent 22: Compile parse_julia_literal directly
# and test with specific inputs

using WasmTarget
using JuliaSyntax

# Direct test: call parse_julia_literal and return type indicator
function test_pjl_result(s::String)
    # Create a textbuf from the string
    txtbuf = Vector{UInt8}(s)
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    range = UInt32(1):UInt32(length(txtbuf))
    result = JuliaSyntax.parse_julia_literal(txtbuf, head, range)
    if result isa Int64
        return Int32(result)
    elseif result isa Symbol
        return Int32(-1)
    elseif result isa String
        return Int32(-6)
    elseif result isa Nothing
        return Int32(-2)
    elseif result isa Bool
        return Int32(-3)
    end
    return Int32(-999)
end

# Same but with K"Identifier"
function test_pjl_ident(s::String)
    txtbuf = Vector{UInt8}(s)
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Identifier", JuliaSyntax.EMPTY_FLAGS)
    range = UInt32(1):UInt32(length(txtbuf))
    result = JuliaSyntax.parse_julia_literal(txtbuf, head, range)
    if result isa Symbol
        return Int32(1) # Correct: Identifier → Symbol
    elseif result isa Int64
        return Int32(-1) # Bug: Identifier → Int
    end
    return Int32(-999)
end

# Native Julia
println("=== Native Julia Ground Truth ===")
println("  test_pjl_result(\"1\") = ", test_pjl_result("1"))
println("  test_pjl_result(\"42\") = ", test_pjl_result("42"))
println("  test_pjl_ident(\"x\") = ", test_pjl_ident("x"))

# Compile
println("\n=== Compiling ===")
for (name, fn) in [
    ("test_pjl_result", test_pjl_result),
    ("test_pjl_ident", test_pjl_ident),
]
    print("  $name: ")
    try
        bytes = compile(fn, (String,))
        outpath = "WasmTarget.jl/browser/$(name).wasm"
        write(outpath, bytes)
        println("$(length(bytes)) bytes → $outpath")
    catch e
        println("COMPILE ERROR: $(sprint(showerror, e)[1:min(300, end)])")
    end
end

println("\nDone.")
