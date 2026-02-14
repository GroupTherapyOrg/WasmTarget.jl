#!/usr/bin/env julia
# PURE-325 Agent 22: Test if SyntaxHead.kind value survives through code
# parse_julia_literal does getfield(head, :kind) at stmt 1, then uses it at stmt 513
# The value flows through hundreds of statements. Does it get corrupted?

using WasmTarget
using JuliaSyntax

# Test: SyntaxHead.kind survives through String creation (like parse_julia_literal)
# This mimics the real code path: extract kind, create val_str from txtbuf,
# THEN compare kind against K"Integer"
function test_kind_survives_string(head::JuliaSyntax.SyntaxHead)
    k = JuliaSyntax.kind(head)
    # Simulate what parse_julia_literal does between getfield and === K"Integer":
    # It creates a String from the text buffer
    # Do some work to prevent folding
    txtbuf = UInt8[0x31]  # "1"
    range = UInt32(1):UInt32(1)

    # Check K"Float" first (like parse_julia_literal does)
    if k === JuliaSyntax.K"Float"
        return Int32(1)
    end

    # Create val_str (this is what happens between Float check and Integer check)
    val_str = String(txtbuf[range])

    # Now check K"Integer"
    if k === JuliaSyntax.K"Integer"
        return Int32(5)
    end

    # Check identifier
    if JuliaSyntax.is_identifier(k)
        return Int32(6)
    end

    return Int32(0)
end

# Test: Same but with KSet comparison in between (parse_julia_literal has KSet"String CmdString" check)
function test_kind_with_kset(head::JuliaSyntax.SyntaxHead)
    k = JuliaSyntax.kind(head)

    # Float check
    if k === JuliaSyntax.K"Float"
        return Int32(1)
    end

    # Float32 check
    if k === JuliaSyntax.K"Float32"
        return Int32(2)
    end

    # Char check
    if k === JuliaSyntax.K"Char"
        return Int32(3)
    end

    # Bool check (parse_julia_literal has K"Bool")
    if k === JuliaSyntax.K"Bool"
        return Int32(4)
    end

    # Integer check
    if k === JuliaSyntax.K"Integer"
        return Int32(5)
    end

    # Identifier check
    if JuliaSyntax.is_identifier(k)
        return Int32(6)
    end

    return Int32(0)
end

# Native Julia
println("=== Native Julia Ground Truth ===")
int_head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
id_head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Identifier", JuliaSyntax.EMPTY_FLAGS)
float_head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Float", JuliaSyntax.EMPTY_FLAGS)

println("  test_kind_survives_string(Integer) = ", test_kind_survives_string(int_head))
println("  test_kind_survives_string(Identifier) = ", test_kind_survives_string(id_head))
println("  test_kind_survives_string(Float) = ", test_kind_survives_string(float_head))
println("  test_kind_with_kset(Integer) = ", test_kind_with_kset(int_head))
println("  test_kind_with_kset(Identifier) = ", test_kind_with_kset(id_head))
println("  test_kind_with_kset(Float) = ", test_kind_with_kset(float_head))

# IR analysis
println("\n=== IR Analysis ===")
for (name, fn) in [
    ("test_kind_survives_string", test_kind_survives_string),
    ("test_kind_with_kset", test_kind_with_kset),
]
    ir = Base.code_typed(fn, (JuliaSyntax.SyntaxHead,))[1][1]
    println("  $name: $(length(ir.code)) statements")
end

# Compile
println("\n=== Compiling ===")
for (name, fn) in [
    ("test_kind_survives_string", test_kind_survives_string),
    ("test_kind_with_kset", test_kind_with_kset),
]
    print("  $name: ")
    try
        bytes = compile(fn, (JuliaSyntax.SyntaxHead,))
        outpath = joinpath("browser", "$(name).wasm")
        write(outpath, bytes)
        println("$(length(bytes)) bytes → $outpath")
    catch e
        println("COMPILE ERROR: $(sprint(showerror, e)[1:min(300, end)])")
    end
end

println("\nDone.")
