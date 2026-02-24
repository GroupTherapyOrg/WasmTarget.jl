using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
const Compiler = Core.Compiler

# Get the Julia IR for builtin_effects to understand the types
bl = Compiler.PartialsLattice{Compiler.ConstsLattice}
results = code_typed(Compiler.builtin_effects, (bl, Core.Builtin, Vector{Any}, Any); optimize=true)
ir, rt = results[1]
println("Return type: $rt")
println("Stmts: $(length(ir.stmts))")

# Find all statements around the error area
# The error is at i64.mul — look for multiplication operations
for i in 1:length(ir.stmts)
    inst = ir.stmts[i][:inst]
    typ = ir.stmts[i][:type]
    # Look for multiplication or operations that produce i64 but might involve externref
    if string(inst) |> s -> (occursin("*", s) || occursin("mul_int", s) || occursin("sizeof", s) || occursin("Core.sizeof", s))
        println("  %$i ::$typ = $inst")
        # Print surrounding context
        for j in max(1,i-3):min(length(ir.stmts),i+3)
            jinst = ir.stmts[j][:inst]
            jtyp = ir.stmts[j][:type]
            println("    %$j ::$jtyp = $jinst")
        end
        println()
    end
end

# Also look for nfields which returns Int and could involve externref
println("\n=== Statements with nfields/sizeof ===")
for i in 1:length(ir.stmts)
    inst = ir.stmts[i][:inst]
    typ = ir.stmts[i][:type]
    if string(inst) |> s -> occursin("nfields", s) || occursin("sizeof", s)
        println("  %$i ::$typ = $inst")
    end
end
