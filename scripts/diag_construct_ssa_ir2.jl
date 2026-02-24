# Find ALL statements in construct_ssa! that produce Core.EnterNode values
using WasmTarget

f = getfield(Core.Compiler, Symbol("construct_ssa!"))
sig = first(methods(f)).sig
arg_types = Tuple(sig.parameters[2:end])
ci_list = code_typed(f, arg_types)
if !isempty(ci_list)
    ci, ret = ci_list[1]
    println("Total statements: $(length(ci.code))")

    # Find ALL statements with EnterNode type
    for (i, stmt) in enumerate(ci.code)
        stmt_type = ci.ssavaluetypes[i]
        if stmt_type === Core.EnterNode || (stmt_type isa DataType && stmt_type <: Core.EnterNode)
            println("\nStatement $i (type=$stmt_type): $(typeof(stmt))")
            println("  $stmt")
            if stmt isa Expr
                println("  head: $(stmt.head)")
                println("  args: $(stmt.args)")
            elseif stmt isa Core.PhiNode
                println("  edges: $(stmt.edges)")
                println("  values: $(stmt.values)")
            end
        end
    end

    # Also find PhiNode statements where any value has EnterNode type
    println("\n=== PhiNodes referencing EnterNode-typed values ===")
    for (i, stmt) in enumerate(ci.code)
        if stmt isa Core.PhiNode
            for val in stmt.values
                if val isa Core.SSAValue
                    val_type = ci.ssavaluetypes[val.id]
                    if val_type === Core.EnterNode || (val_type isa DataType && val_type <: Core.EnterNode)
                        println("\nPhiNode at $i: edges=$(stmt.edges) values=$(stmt.values)")
                        println("  Result type: $(ci.ssavaluetypes[i])")
                        break
                    end
                end
            end
        end
    end

    # Also check for isdefined that references EnterNode
    println("\n=== isdefined calls ===")
    for (i, stmt) in enumerate(ci.code)
        if stmt isa Expr && stmt.head === :call
            func_arg = stmt.args[1]
            if func_arg isa GlobalRef && func_arg.name === :isdefined
                println("Statement $i: $stmt")
                println("  Type: $(ci.ssavaluetypes[i])")
            end
        end
    end
end
