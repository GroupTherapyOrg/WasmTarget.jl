#!/usr/bin/env julia
# diag_6021c_ir.jl — get Julia IR for early_inline_special_case to understand SSA types
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

println("=== Julia IR for early_inline_special_case ===")
println("Arg types: $arg_types")

# Get code_typed
ct = code_typed(func, arg_types; optimize=true)
if isempty(ct)
    println("No typed code found")
else
    ci, rt = ct[1]
    println("Return type: $rt")
    println("Slots:")
    for (i, s) in enumerate(ci.slottypes)
        println("  slot $i: $s")
    end
    println("\nSSA Values ($(length(ci.code)) stmts):")
    for (i, (stmt, typ)) in enumerate(zip(ci.code, ci.ssavaluetypes))
        # Only show if type involves Int, Intrinsic, or is externref-likely
        if typ isa Union && (Nothing <: typ || typ != Any)
            println("  %$i ::$typ = $stmt")
        elseif typ isa Type && (
            typ <: Integer || typ <: IntrinsicFunction ||
            typ <: Symbol || typ <: Bool ||
            (typ isa Union && Nothing <: typ)
        )
            println("  %$i ::$typ = $stmt")
        elseif contains(repr(stmt), "==") || contains(repr(stmt), "===")
            println("  %$i ::$typ = $stmt  ← comparison")
        end
    end
end

println("\n=== All SSA values ===")
ct2 = code_typed(func, arg_types; optimize=false)
if !isempty(ct2)
    ci2, _ = ct2[1]
    for (i, (stmt, typ)) in enumerate(zip(ci2.code, ci2.ssavaluetypes))
        println("  %$i ::$typ = $stmt")
    end
end
