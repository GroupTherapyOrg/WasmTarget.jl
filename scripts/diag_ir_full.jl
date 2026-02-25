#!/usr/bin/env julia
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    fn = WasmTarget.register_tuple_type!
    arg_types = Tuple{typeof(fn), WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}}}
    
    ci = Base.code_typed_by_type(arg_types; optimize=false)
    if isempty(ci)
        println("No code info found")
        return
    end
    
    code_info = ci[1][1]
    println("Total statements: $(length(code_info.code))")
    
    # Print ALL statements that are Expr with :invoke head
    println("\n=== :invoke STATEMENTS ===")
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Expr && stmt.head === :invoke
            ci_arg = stmt.args[1]
            # Extract method name
            mname = "?"
            if ci_arg isa Core.CodeInstance
                mname = string(ci_arg.def.def.name)
            end
            ssatype = i <= length(code_info.ssavaluetypes) ? code_info.ssavaluetypes[i] : "?"
            n_args = length(stmt.args) - 2  # -1 for CodeInstance, -1 for func
            println("SSA $i [$ssatype]: invoke $mname ($(n_args) args)")
        end
    end

    # Print ALL statements that are :call
    println("\n=== :call STATEMENTS ===")
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Expr && stmt.head === :call
            func = stmt.args[1]
            fname = if func isa GlobalRef
                "$(func.mod).$(func.name)"
            elseif func isa Core.SSAValue
                "SSA($(func.id))"
            else
                string(func)
            end
            ssatype = i <= length(code_info.ssavaluetypes) ? code_info.ssavaluetypes[i] : "?"
            n_args = length(stmt.args) - 1
            println("SSA $i [$ssatype]: call $fname ($(n_args) args)")
        end
    end
    
    # Look for GotoIfNot near throws — find the throw-related SSAs
    println("\n=== GotoIfNot + GotoNode STRUCTURE ===")
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Core.GotoIfNot
            println("SSA $i: GotoIfNot($(stmt.cond), dest=$(stmt.dest))")
        elseif stmt isa Core.GotoNode
            println("SSA $i: GotoNode($(stmt.label))")
        elseif stmt isa Core.ReturnNode
            rv = isdefined(stmt, :val) ? stmt.val : "unreachable"
            println("SSA $i: ReturnNode($rv)")
        end
    end
end
main()
