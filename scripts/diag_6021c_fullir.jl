#!/usr/bin/env julia
# Show full Julia IR for early_inline_special_case to find integer comparisons
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)
@isdefined(SourceFile) || (@eval const SourceFile = JuliaSyntax.SourceFile)
@isdefined(InternalCodeCache) || (@eval const InternalCodeCache = Core.Compiler.InternalCodeCache)
@isdefined(WorldRange) || (@eval const WorldRange = Core.Compiler.WorldRange)
@isdefined(InferenceResult) || (@eval const InferenceResult = Core.Compiler.InferenceResult)
@isdefined(IRCode) || (@eval const IRCode = Core.Compiler.IRCode)
@isdefined(CFG) || (@eval const CFG = Core.Compiler.CFG)
@isdefined(InstructionStream) || (@eval const InstructionStream = Core.Compiler.InstructionStream)

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
all_lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), all_lines)
line142 = data_lines[findfirst(l -> startswith(l, "142 |"), data_lines)]
parts = split(line142, " | ")
func = getfield(eval(Meta.parse(strip(parts[2]))), Symbol(strip(parts[3])))
arg_types = eval(Meta.parse(strip(parts[4])))

# code_typed with the specific WasmInterpreter signature
# Use the same approach as compile() but with code_typed
ct = code_typed(func, arg_types; optimize=true)
if !isempty(ct)
    ci, rt = ct[1]
    println("Return type: $rt")
    println("$(length(ci.code)) stmts, $(length(ci.ssavaluetypes)) types")

    # Look for integer comparisons (eq, !=) — their args and types
    println("\n=== Integer-related statements ===")
    for (i, (stmt, typ)) in enumerate(zip(ci.code, ci.ssavaluetypes))
        s = repr(stmt)
        if contains(s, "82") || contains(s, "84") || contains(s, "85") || contains(s, "86") || contains(s, "88")
            println("  %$i ::$typ = $stmt")
        end
        if contains(s, "eq") || contains(s, "===") || contains(s, "IntrinsicFunction") || contains(s, "Intrinsics")
            println("  %$i ::$typ = $stmt")
        end
    end

    # Show all Union types (potential problematic allocations)
    println("\n=== Union-typed SSA values ===")
    for (i, (stmt, typ)) in enumerate(zip(ci.code, ci.ssavaluetypes))
        if typ isa Union && typ != Union{}
            println("  %$i ::$typ = $stmt")
        end
    end

    # Count by type
    types_count = Dict{Any,Int}()
    for t in ci.ssavaluetypes
        types_count[t] = get(types_count, t, 0) + 1
    end
    println("\n=== Type distribution (top 10) ===")
    sorted = sort(collect(types_count), by=x->-x[2])
    for (t, cnt) in sorted[1:min(10,end)]
        println("  $cnt × $t")
    end
end
