#!/usr/bin/env julia
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    fn = WasmTarget.register_tuple_type!
    arg_types = Tuple{typeof(fn), WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}}}
    
    # OPTIMIZED IR
    ci = Base.code_typed_by_type(arg_types; optimize=true)
    code_info = ci[1][1]
    
    # Find throw-related calls
    println("=== THROW CALLS (optimized IR) ===")
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Expr
            func = stmt.args[1]
            if func isa GlobalRef && (func.name === :throw || func.name === :throw_boundserror || func.name === :throw_inexacterror)
                # Print context
                s = max(1, i-3)
                e = min(length(code_info.code), i+2)
                for j in s:e
                    ssatype = j <= length(code_info.ssavaluetypes) ? code_info.ssavaluetypes[j] : "?"
                    marker = j == i ? " <<<" : ""
                    println("SSA $j [$ssatype]: $(code_info.code[j])$marker")
                end
                println()
            end
        end
    end
    
    # Also check for invoke to throw
    println("=== INVOKE TO THROW (optimized IR) ===")
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Expr && stmt.head === :invoke
            ci_arg = stmt.args[1]
            mname = "?"
            try
                mname = string(ci_arg.def.def.name)
            catch; end
            if contains(mname, "throw") || contains(mname, "error") || contains(mname, "Error")
                ssatype = i <= length(code_info.ssavaluetypes) ? code_info.ssavaluetypes[i] : "?"
                println("SSA $i [$ssatype]: invoke $mname args=$(stmt.args[3:end])")
            end
        end
    end
end
main()
