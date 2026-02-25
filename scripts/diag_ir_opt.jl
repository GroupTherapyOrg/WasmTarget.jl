#!/usr/bin/env julia
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    fn = WasmTarget.register_tuple_type!
    arg_types = Tuple{typeof(fn), WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}}}
    
    # OPTIMIZED IR - what compile_multi actually uses
    ci = Base.code_typed_by_type(arg_types; optimize=true)
    if isempty(ci)
        println("No code info found")
        return
    end
    
    code_info = ci[1][1]
    println("Total statements: $(length(code_info.code))")
    
    # Find all :new expressions 
    println("\n=== :new EXPRESSIONS ===")
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Expr && stmt.head === :new
            struct_type = stmt.args[1]
            n_fields = length(stmt.args) - 1
            resolved_type = nothing
            if struct_type isa GlobalRef
                try resolved_type = getfield(struct_type.mod, struct_type.name) catch; end
            elseif struct_type isa DataType
                resolved_type = struct_type
            end
            is_exc = resolved_type !== nothing && try resolved_type <: Exception catch; false end
            fc = resolved_type isa DataType ? fieldcount(resolved_type) : "?"
            println("SSA $i: :new($(resolved_type !== nothing ? resolved_type : struct_type), $n_fields fields, fieldcount=$fc, <:Exception=$is_exc)")
            # Show fieldtypes for small structs
            if resolved_type isa DataType && fc isa Int && fc <= 3
                try println("  fieldtypes: $(fieldtypes(resolved_type))") catch; end
            end
            # Show args
            for (j, fv) in enumerate(stmt.args[2:end])
                println("  arg $j: $fv ($(typeof(fv)))")
            end
        end
    end
    
    # Count expr heads
    println("\n=== EXPR HEAD COUNTS ===")
    head_counts = Dict{Symbol, Int}()
    for stmt in code_info.code
        if stmt isa Expr
            head_counts[stmt.head] = get(head_counts, stmt.head, 0) + 1
        end
    end
    for (h, c) in sort(collect(head_counts))
        println("  $h: $c")
    end
end
main()
