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
    
    # Find all statements that reference GlobalRef(:throw) 
    println("=== STATEMENTS NEAR throw ===")
    for (i, stmt) in enumerate(code_info.code)
        is_throw = false
        if stmt isa Expr
            for arg in stmt.args
                if arg isa GlobalRef && arg.name === :throw
                    is_throw = true
                end
                if arg isa Core.SSAValue
                    # Check if it references a throw statement
                end
            end
        end
        if is_throw
            # Print context: 5 statements before and after
            s = max(1, i-5)
            e = min(length(code_info.code), i+2)
            for j in s:e
                marker = j == i ? " <<<" : ""
                ssatype = j <= length(code_info.ssavaluetypes) ? code_info.ssavaluetypes[j] : "?"
                println("SSA $j [$(ssatype)]: $(code_info.code[j])$marker")
            end
            println()
        end
    end
    
    # Also look for any struct-like creation (Expr(:new, ...))
    println("=== ALL EXPR HEADS ===")
    heads = Set{Symbol}()
    for stmt in code_info.code
        if stmt isa Expr
            push!(heads, stmt.head)
        end
    end
    println(heads)
    
    # Check for :splatnew
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Expr && stmt.head === :splatnew
            println("SSA $i: :splatnew $(stmt.args)")
        end
    end
end
main()
