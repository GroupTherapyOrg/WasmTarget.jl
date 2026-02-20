#!/usr/bin/env julia
# diag_compact_ir.jl - Get Julia IR for compact! and check what statement 21 does
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@eval const Compiler = Core.Compiler
@eval const IRCode = Core.Compiler.IRCode

f = Compiler.compact!
arg_types = (IRCode, Bool)
println("=== Julia IR for compact! (unoptimized) ===")
results = code_typed(f, arg_types; optimize=false)
if !isempty(results)
    ci, rt = results[1]
    println("Return type: $rt")
    println("Statements ($(length(ci.code))):")
    for (i, stmt) in enumerate(ci.code)
        t = ci.ssavaluetypes[i]
        println("  %$i ::$t = $stmt")
    end
else
    println("No results from code_typed(optimize=false)")
end

println()
println("=== Julia IR for compact! (optimized) ===")
results2 = code_typed(f, arg_types; optimize=true)
if !isempty(results2)
    ci2, rt2 = results2[1]
    println("Return type: $rt2")
    println("Statements ($(length(ci2.code))):")
    for (i, stmt) in enumerate(ci2.code)
        t = ci2.ssavaluetypes[i]
        println("  %$i ::$t = $stmt")
    end
else
    println("No results from code_typed(optimize=true)")
end
