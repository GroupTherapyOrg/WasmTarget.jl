using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Get the IR for construct_ssa! to find :new expressions with 2-field struct types
arg_types = (Core.CodeInfo, Core.Compiler.IRCode, Core.Compiler.OptimizationState{WasmInterpreter}, Core.Compiler.GenericDomTree{false}, Vector{Core.Compiler.SlotInfo}, Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice})

# Get typed code
println("=== IR for construct_ssa! ===")
ct = Base.code_typed(Core.Compiler.construct_ssa!, arg_types; optimize=true)
if isempty(ct)
    println("No code_typed result")
    exit(1)
end
ci, ret = ct[1]
println("Total statements: $(length(ci.code))")

# Find all :new expressions that create types with 2 fields
println("\nLooking for :new expressions that create 2-field struct types...")
for (i, stmt) in enumerate(ci.code)
    if stmt isa Expr && stmt.head === :new
        struct_type = stmt.args[1]
        n_args = length(stmt.args) - 1
        # Check if this type has 2 fields
        fc = -1
        actual_type = nothing
        try
            actual_type = struct_type isa GlobalRef ? getfield(struct_type.mod, struct_type.name) : struct_type
            fc = fieldcount(actual_type)
        catch
        end
        if fc == 2
            println("  SSA $i: :new($(actual_type), ...) [$n_args field args provided] — type has $fc fields")
            for (j, arg) in enumerate(stmt.args[2:end])
                println("    arg $j: $arg ($(typeof(arg)))")
            end
            # Show field types of the struct
            if actual_type !== nothing
                for fi in 1:fc
                    println("    field $fi type: $(fieldtype(actual_type, fi))")
                end
            end
        end
    end
end
