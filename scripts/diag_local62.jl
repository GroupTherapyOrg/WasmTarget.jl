#!/usr/bin/env julia
# diag_local62.jl — Find mul_int in builtin_effects IR and identify func 15

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)

bl = Core.Compiler.InferenceLattice{Core.Compiler.ConditionalsLattice{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}}}

# Look at builtin_effects IR for mul_int
println("=== Julia IR for builtin_effects: looking for mul operations ===")
results = code_typed(Core.Compiler.builtin_effects, (bl, Core.Builtin, Vector{Any}, Any); optimize=true)
ci, rt = results[1]
println("Total stmts: $(length(ci.code))")

for i in 1:length(ci.code)
    inst = ci.code[i]
    typ = ci.ssavaluetypes[i]
    inst_str = sprint(show, inst)
    if contains(inst_str, "mul_int") || contains(inst_str, "mul_float") ||
       contains(inst_str, "checked_smul") || contains(inst_str, "checked_umul")
        println("  %$i ::$typ = $inst_str")
        # Show context
        for j in max(1,i-5):min(length(ci.code),i+5)
            inst2 = ci.code[j]
            typ2 = ci.ssavaluetypes[j]
            mark = j == i ? ">>>" : "   "
            println("  $mark %$j ::$typ2 = $(sprint(show, inst2)[1:min(100,end)])")
        end
        println()
    end
end

# Also search for any i64.mul equivalent (Base.mul_int, Core.Intrinsics.mul_int)
println("\n=== All arithmetic binary ops ===")
for i in 1:length(ci.code)
    inst = ci.code[i]
    typ = ci.ssavaluetypes[i]
    if inst isa Expr && inst.head === :call
        func = inst.args[1]
        if func isa GlobalRef
            name = string(func.name)
            if contains(name, "mul") || contains(name, "add") || contains(name, "sub") || contains(name, "div")
                println("  %$i ::$typ = $(sprint(show, inst)[1:min(100,end)])")
            end
        elseif func isa Core.IntrinsicFunction
            println("  %$i ::$typ = intrinsic $(sprint(show, inst)[1:min(100,end)])")
        end
    end
end
