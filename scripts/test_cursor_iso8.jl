#!/usr/bin/env julia
# PURE-325 Agent 22: Diagnose parse_julia_literal branch with RUNTIME Kind
# Previous tests were constant-folded. This one forces runtime behavior.

using WasmTarget
using JuliaSyntax

# Test: Which branch does parse_julia_literal take with RUNTIME Kind?
# Return different values for each possibility
function test_literal_branch_rt()
    txtbuf = UInt8[0x31]  # "1"
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    range = UInt32(1):UInt32(1)
    result = JuliaSyntax.parse_julia_literal(txtbuf, head, range)
    # Check what type we got
    if result isa Int64
        return Int32(result)  # Should be 1
    elseif result isa Int32
        return Int32(1000 + result)
    elseif result isa Symbol
        return Int32(-1)  # Symbol = identifier branch taken
    elseif result isa Nothing
        return Int32(-2)  # Nothing = syntax_kind branch
    elseif result isa Bool
        return Int32(-3)  # Bool
    elseif result isa Float64
        return Int32(-4)
    elseif result isa Char
        return Int32(-5)
    elseif result isa String
        return Int32(-6)
    end
    return Int32(-999)  # Unknown type
end

# Test: What does kind(head) return at RUNTIME?
# Use the SyntaxHead passed through parse_julia_literal
function test_kind_value_rt()
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    k = JuliaSyntax.kind(head)
    return Int32(reinterpret(UInt16, k))
end

# Test: Does the k == K"Integer" comparison work at runtime?
# Force the head to be runtime-constructed
function test_integer_check_rt()
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    k = JuliaSyntax.kind(head)
    # Multiple checks, return which one matched
    if k == JuliaSyntax.K"Float"
        return Int32(1)
    end
    if k == JuliaSyntax.K"Integer"
        return Int32(44) # K"Integer" = 44
    end
    if JuliaSyntax.is_identifier(k)
        return Int32(100)
    end
    if JuliaSyntax.is_operator(k)
        return Int32(200)
    end
    return Int32(0)
end

# Native Julia
println("=== Native Julia Ground Truth ===")
println("  test_literal_branch_rt() = ", test_literal_branch_rt())
println("  test_kind_value_rt() = ", test_kind_value_rt())
println("  test_integer_check_rt() = ", test_integer_check_rt())

# Check the code_typed to see if these are constant-folded
println("\n=== IR Analysis ===")
ir = Base.code_typed(test_literal_branch_rt, ())[1][1]
println("  test_literal_branch_rt IR: $(length(ir.code)) statements")
ir2 = Base.code_typed(test_kind_value_rt, ())[1][1]
println("  test_kind_value_rt IR: $(length(ir2.code)) statements")

# Compile
println("\n=== Compiling ===")
for (name, fn) in [
    ("test_literal_branch_rt", test_literal_branch_rt),
    ("test_kind_value_rt", test_kind_value_rt),
    ("test_integer_check_rt", test_integer_check_rt),
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
