# Print statements around 5488-5497 to understand the full pattern
using WasmTarget

f = getfield(Core.Compiler, Symbol("construct_ssa!"))
sig = first(methods(f)).sig
arg_types = Tuple(sig.parameters[2:end])
ci_list = code_typed(f, arg_types)
if !isempty(ci_list)
    ci, ret = ci_list[1]
    println("=== Statements 5480-5500 ===")
    for i in 5480:min(5500, length(ci.code))
        stmt = ci.code[i]
        stmt_type = ci.ssavaluetypes[i]
        println("  $i ($(typeof(stmt)), type=$stmt_type): $stmt")
    end

    # Also check what %5257 is (the value being PiNode'd)
    println("\n=== Statement 5257 ===")
    println("  5257: $(ci.code[5257]) type=$(ci.ssavaluetypes[5257])")

    # Check what %5492 is (the scope value)
    if 5492 <= length(ci.code)
        println("  5492: $(ci.code[5492]) type=$(ci.ssavaluetypes[5492])")
    end

    # Check what %5488 is (catch_dest)
    if 5488 <= length(ci.code)
        println("  5488: $(ci.code[5488]) type=$(ci.ssavaluetypes[5488])")
    end

    # Now look at what references %5497 (the phi result)
    println("\n=== Statements using %5497 ===")
    for (i, stmt) in enumerate(ci.code)
        if stmt isa Expr
            for arg in stmt.args
                if arg isa Core.SSAValue && arg.id == 5497
                    println("  $i: $stmt type=$(ci.ssavaluetypes[i])")
                end
            end
        elseif stmt isa Core.PhiNode
            for val in stmt.values
                if val isa Core.SSAValue && val.id == 5497
                    println("  $i (phi): edges=$(stmt.edges) values=$(stmt.values) type=$(ci.ssavaluetypes[i])")
                end
            end
        end
    end

    # Check the getfield that accesses EnterNode scope
    println("\n=== getfield statements on EnterNode ===")
    for (i, stmt) in enumerate(ci.code)
        if stmt isa Expr && stmt.head === :call
            if length(stmt.args) >= 3 && stmt.args[1] isa GlobalRef && stmt.args[1].name === :getfield
                field_arg = stmt.args[3]
                if field_arg isa QuoteNode && field_arg.value === :scope
                    println("  $i: $stmt type=$(ci.ssavaluetypes[i])")
                elseif field_arg === :scope
                    println("  $i: $stmt type=$(ci.ssavaluetypes[i])")
                end
            end
        end
    end
end
