#!/usr/bin/env julia
# Dump the IR of builtin_effects to understand the dead code / live code boundary

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

const Compiler = Core.Compiler

# Get the typed IR
argtypes = Tuple{Compiler.PartialsLattice{Compiler.ConstsLattice}, Core.Builtin, Vector{Any}, Any}
ci = Base.code_typed_by_type(argtypes; optimize=true)

if !isempty(ci)
    code_info, ret_type = ci[1]
    println("Return type: $ret_type")
    println("Stmts: $(length(code_info.code))")
    println("SSA types: $(length(code_info.ssavaluetypes))")
    println()

    # Look for SSA values typed as Any (→ externref) that are used in arithmetic
    for (i, stmt) in enumerate(code_info.code)
        ssa_type = code_info.ssavaluetypes[i]
        # Find statements that produce values used in i64 operations
        # Focus on stmts around the error area
        if ssa_type === Any || ssa_type === Union{}
            println("SSA $i: type=$ssa_type stmt=$(typeof(stmt))")
            if stmt isa Expr
                println("  expr: head=$(stmt.head) args=$(stmt.args[1:min(3,length(stmt.args))])")
            end
            # Look for uses of this SSA
            for (j, use_stmt) in enumerate(code_info.code)
                if use_stmt isa Expr
                    for arg in use_stmt.args
                        if arg isa Core.SSAValue && arg.id == i
                            use_type = code_info.ssavaluetypes[j]
                            println("  used by SSA $j: type=$use_type $(typeof(use_stmt))")
                            if use_stmt isa Expr
                                println("    head=$(use_stmt.head) args=$(use_stmt.args[1:min(3,length(use_stmt.args))])")
                            end
                        end
                    end
                end
            end
        end
    end

    # Find i64-producing stmts that reference Any-typed SSAs
    println("\n\n=== Looking for Int64/UInt64-typed stmts referencing Any-typed SSAs ===")
    for (i, stmt) in enumerate(code_info.code)
        ssa_type = code_info.ssavaluetypes[i]
        if ssa_type in (Int64, UInt64, Int, UInt)
            if stmt isa Expr
                for arg in stmt.args
                    if arg isa Core.SSAValue
                        arg_type = code_info.ssavaluetypes[arg.id]
                        if arg_type === Any || arg_type === Union{}
                            println("SSA $i (type=$ssa_type): uses SSA $(arg.id) (type=$arg_type)")
                            println("  stmt: $(stmt.head) $(stmt.args)")
                        end
                    end
                end
            end
        end
    end

    # Dump full IR (with line numbers and types)
    println("\n\n=== FULL IR (stmts with types) ===")
    for (i, stmt) in enumerate(code_info.code)
        ssa_type = code_info.ssavaluetypes[i]
        # Mark dead code (Union{} type)
        marker = ssa_type === Union{} ? " [DEAD]" : ""
        println("%$i [$ssa_type]$marker = $stmt")
    end
else
    println("No code_typed result found")
end
