using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

arg_types = (Core.CodeInfo, Core.Compiler.IRCode, Core.Compiler.OptimizationState{WasmInterpreter}, Core.Compiler.GenericDomTree{false}, Vector{Core.Compiler.SlotInfo}, Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice})

ct = Base.code_typed(Core.Compiler.construct_ssa!, arg_types; optimize=true)
ci, ret = ct[1]

# Check SSA types
println("SSA 5703 type: $(ci.ssavaluetypes[5703])")
println("SSA 5701 type: $(ci.ssavaluetypes[5701])")
println("SSA 5705 type: $(ci.ssavaluetypes[5705])")

# Check the wasm type mapping
println("\nEnterNode fields:")
for i in 1:fieldcount(Core.EnterNode)
    println("  field $i: $(fieldname(Core.EnterNode, i)) :: $(fieldtype(Core.EnterNode, i))")
end

# What type does EnterNode get in Wasm?
println("\nWasm type for Core.EnterNode: $(WasmTarget.julia_to_wasm_type(Core.EnterNode))")
