# check_ir_deps.jl — Check if optimization passes are in typed IR
using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== Checking typed IR for eval_julia_to_bytes ===")
try
    ir_result = Base.code_ircode(eval_julia_to_bytes, (String,))
    if length(ir_result) > 0
        ir, ret = ir_result[1]
        println("Return type: $ret")
        println("Statement count: $(length(ir.stmts.stmt))")

        opt_names = ["compact!", "adce_pass!", "sroa_pass!", "construct_ssa!", "builtin_effects"]
        found_opt = String[]
        for (i, stmt) in enumerate(ir.stmts.stmt)
            s = string(stmt)
            for name in opt_names
                if occursin(name, s)
                    push!(found_opt, "$name at stmt $i: $s")
                end
            end
        end
        println("Optimization pass references in IR: $(length(found_opt))")
        for ref in found_opt
            println("  $ref")
        end
        if length(found_opt) == 0
            println("  NONE — optimizer eliminated dead branches!")
        end
    end
catch e
    println("Error: $e")
end

# Now check: does get_typed_ir (used by compile_multi) also see them?
println("\n=== Checking WasmTarget.get_typed_ir ===")
try
    ir_entries = WasmTarget.get_typed_ir(eval_julia_to_bytes, (String,))
    println("Got $(length(ir_entries)) IR entries")
    for (i, entry) in enumerate(ir_entries)
        println("  $i: $(entry)")
    end
catch e
    println("get_typed_ir error: $e")
    println(sprint(showerror, e))
end
