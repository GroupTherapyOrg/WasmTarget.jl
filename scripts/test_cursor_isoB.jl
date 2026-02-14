#!/usr/bin/env julia
# PURE-325 Agent 22: Isolate SyntaxHead.kind extraction + === comparison
# This time, prevent constant folding by taking SyntaxHead as a parameter.

using WasmTarget
using JuliaSyntax

# Test 1: Extract kind from SyntaxHead and compare with K"Integer"
# Takes SyntaxHead AS PARAMETER to prevent constant folding
# SyntaxHead is a struct → ConcreteRef in Wasm
function test_kind_from_head(head::JuliaSyntax.SyntaxHead)
    k = JuliaSyntax.kind(head)
    if k === JuliaSyntax.K"Integer"
        return Int32(44)
    end
    if k === JuliaSyntax.K"Identifier"
        return Int32(90)
    end
    if k === JuliaSyntax.K"Float"
        return Int32(43)
    end
    return Int32(reinterpret(UInt16, k))
end

# Test 2: Extract kind and just return its numeric value
function test_kind_extract(head::JuliaSyntax.SyntaxHead)
    k = JuliaSyntax.kind(head)
    return Int32(reinterpret(UInt16, k))
end

# Test 3: Direct Kind parameter comparison (not from struct extraction)
function test_kind_direct(k::JuliaSyntax.Kind)
    if k === JuliaSyntax.K"Integer"
        return Int32(44)
    end
    if k === JuliaSyntax.K"Identifier"
        return Int32(90)
    end
    return Int32(reinterpret(UInt16, k))
end

# Test 4: SyntaxHead → kind → is_literal comparison
# Mimics what parse_julia_literal does
function test_kind_is_literal(head::JuliaSyntax.SyntaxHead)
    k = JuliaSyntax.kind(head)
    if k === JuliaSyntax.K"Float"
        return Int32(1)
    elseif k === JuliaSyntax.K"Float32"
        return Int32(2)
    elseif k === JuliaSyntax.K"Char"
        return Int32(3)
    elseif k === JuliaSyntax.K"Integer"
        return Int32(5)
    elseif JuliaSyntax.is_identifier(k)
        return Int32(6)
    elseif JuliaSyntax.is_operator(k)
        return Int32(7)
    else
        return Int32(0)
    end
end

# Native Julia
println("=== Native Julia Ground Truth ===")
int_head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
id_head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Identifier", JuliaSyntax.EMPTY_FLAGS)
float_head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Float", JuliaSyntax.EMPTY_FLAGS)

println("  test_kind_from_head(Integer) = ", test_kind_from_head(int_head))
println("  test_kind_from_head(Identifier) = ", test_kind_from_head(id_head))
println("  test_kind_from_head(Float) = ", test_kind_from_head(float_head))
println("  test_kind_extract(Integer) = ", test_kind_extract(int_head))
println("  test_kind_direct(K\"Integer\") = ", test_kind_direct(JuliaSyntax.K"Integer"))
println("  test_kind_direct(K\"Identifier\") = ", test_kind_direct(JuliaSyntax.K"Identifier"))
println("  test_kind_is_literal(Integer) = ", test_kind_is_literal(int_head))
println("  test_kind_is_literal(Identifier) = ", test_kind_is_literal(id_head))
println("  test_kind_is_literal(Float) = ", test_kind_is_literal(float_head))

# Check IR sizes
println("\n=== IR Analysis ===")
for (name, fn, args) in [
    ("test_kind_from_head", test_kind_from_head, (JuliaSyntax.SyntaxHead,)),
    ("test_kind_extract", test_kind_extract, (JuliaSyntax.SyntaxHead,)),
    ("test_kind_direct", test_kind_direct, (JuliaSyntax.Kind,)),
    ("test_kind_is_literal", test_kind_is_literal, (JuliaSyntax.SyntaxHead,)),
]
    ir = Base.code_typed(fn, args)[1][1]
    println("  $name: $(length(ir.code)) statements")
end

# Compile
println("\n=== Compiling ===")
for (name, fn, args) in [
    ("test_kind_from_head", test_kind_from_head, (JuliaSyntax.SyntaxHead,)),
    ("test_kind_extract", test_kind_extract, (JuliaSyntax.SyntaxHead,)),
    ("test_kind_direct", test_kind_direct, (JuliaSyntax.Kind,)),
    ("test_kind_is_literal", test_kind_is_literal, (JuliaSyntax.SyntaxHead,)),
]
    print("  $name: ")
    try
        bytes = compile(fn, args)
        outpath = joinpath("browser", "$(name).wasm")
        write(outpath, bytes)
        println("$(length(bytes)) bytes → $outpath")
    catch e
        println("COMPILE ERROR: $(sprint(showerror, e)[1:min(300, end)])")
    end
end

println("\nDone.")
