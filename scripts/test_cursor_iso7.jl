#!/usr/bin/env julia
# PURE-325 Agent 22: Narrow down why parse_julia_literal returns Symbol for Integer
# Either the Kind comparison or the KSet `in` check is wrong

using WasmTarget
using JuliaSyntax

# Test: Does `k in KSet"String CmdString"` incorrectly match K"Integer"?
function test_kset_string_match()
    k = JuliaSyntax.K"Integer"
    if k in JuliaSyntax.KSet"String CmdString"
        return Int32(1) # BUG: Integer matched String KSet
    end
    return Int32(0) # Correct: Integer not in String KSet
end

# Test: Which exact branch does parse_julia_literal take?
# Return a different int for each branch
function test_literal_branch()
    txtbuf = UInt8[0x31]  # "1"
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    range = UInt32(1):UInt32(1)
    k = JuliaSyntax.kind(head)

    if k == JuliaSyntax.K"Float"
        return Int32(1)
    elseif k == JuliaSyntax.K"Float32"
        return Int32(2)
    elseif k == JuliaSyntax.K"Char"
        return Int32(3)
    elseif k in JuliaSyntax.KSet"String CmdString"
        return Int32(4)
    elseif k == JuliaSyntax.K"Bool"
        return Int32(5)
    end

    # Past the first set of checks
    if k == JuliaSyntax.K"Integer"
        return Int32(10) # This should fire
    elseif k in JuliaSyntax.KSet"BinInt OctInt HexInt"
        return Int32(11)
    elseif JuliaSyntax.is_identifier(k)
        return Int32(12)
    elseif JuliaSyntax.is_operator(k)
        return Int32(13)
    elseif k == JuliaSyntax.K"error"
        return Int32(14)
    elseif JuliaSyntax.is_keyword(k)
        return Int32(16)
    else
        return Int32(17) # Other/ErrorVal path
    end
end

# Test: Does k == K"Integer" work when k comes from kind(head)?
function test_kind_from_head()
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.EMPTY_FLAGS)
    k = JuliaSyntax.kind(head)
    # Direct comparison
    if k == JuliaSyntax.K"Integer"
        return Int32(1)
    end
    return Int32(0)
end

# Test: Does `k == K"Float"` comparison work?
function test_float_check()
    k = JuliaSyntax.K"Integer"
    if k == JuliaSyntax.K"Float"
        return Int32(1) # BUG
    end
    return Int32(0) # Correct
end

# Native Julia
println("=== Native Julia Ground Truth ===")
println("  test_kset_string_match() = ", test_kset_string_match())
println("  test_literal_branch() = ", test_literal_branch())
println("  test_kind_from_head() = ", test_kind_from_head())
println("  test_float_check() = ", test_float_check())

# Compile
println("\n=== Compiling ===")
for (name, fn) in [
    ("test_kset_string_match", test_kset_string_match),
    ("test_literal_branch", test_literal_branch),
    ("test_kind_from_head", test_kind_from_head),
    ("test_float_check", test_float_check),
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
