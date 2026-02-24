using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

arg_types = (Core.CodeInfo, Core.Compiler.IRCode, Core.Compiler.OptimizationState{WasmInterpreter}, Core.Compiler.GenericDomTree{false}, Vector{Core.Compiler.SlotInfo}, Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice})

ct = Base.code_typed(Core.Compiler.construct_ssa!, arg_types; optimize=true)
ci, ret = ct[1]

# Show IR around SSA 5690-5710 to understand the control flow around the EnterNode constructions
println("=== IR statements 5690-5720 ===")
for i in 5690:min(5720, length(ci.code))
    stmt = ci.code[i]
    stype = i <= length(ci.ssavaluetypes) ? ci.ssavaluetypes[i] : "?"
    println("  %$i = $stmt  :: $stype")
end
