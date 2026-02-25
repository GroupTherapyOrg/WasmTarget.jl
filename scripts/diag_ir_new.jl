#!/usr/bin/env julia
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    fn = WasmTarget.register_tuple_type!
    arg_types = Tuple{typeof(fn), WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}}}
    
    # Get the code info using code_typed (may_optimize=false style)
    ci = Base.code_typed_by_type(arg_types; optimize=false)
    if isempty(ci)
        println("No code info found")
        return
    end
    
    code_info = ci[1][1]
    
    # Find all :new expressions
    println("=== :new EXPRESSIONS ===")
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Expr && stmt.head === :new
            struct_type = stmt.args[1]
            n_fields = length(stmt.args) - 1
            println("SSA $i: :new($struct_type, $(n_fields) fields)")
            # Check if struct_type is Exception
            resolved_type = nothing
            if struct_type isa GlobalRef
                try
                    resolved_type = getfield(struct_type.mod, struct_type.name)
                catch; end
            elseif struct_type isa DataType
                resolved_type = struct_type
            end
            if resolved_type !== nothing
                is_exc = try resolved_type <: Exception catch; false end
                println("  Resolved: $resolved_type, <: Exception: $is_exc")
                if resolved_type isa DataType && fieldcount(resolved_type) <= 5
                    println("  Fieldnames: $(fieldnames(resolved_type))")
                    try println("  Fieldtypes: $(fieldtypes(resolved_type))") catch; end
                end
            end
            # Print field values
            for (j, fv) in enumerate(stmt.args[2:end])
                println("  field $j: $fv ($(typeof(fv)))")
            end
        end
    end
    
    # Also find throw calls
    println("\n=== throw CALLS ===")
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
            func_arg = stmt.args[1]
            fname = nothing
            if func_arg isa GlobalRef
                fname = func_arg.name
            elseif func_arg isa CodeInstance
                fname = func_arg.def.def.name
            end
            if fname === :throw
                println("SSA $i: throw($(stmt.args[2:end]))")
            end
        end
    end
end
main()
