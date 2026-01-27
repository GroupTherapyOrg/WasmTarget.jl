#!/usr/bin/env julia
using Pkg
Pkg.activate(dirname(@__DIR__))

using WasmTarget
using InteractiveUtils: @code_typed

# Get the typed IR for token_list_new
println("=== IR for token_list_new ===\n")
code = @code_typed WasmTarget.token_list_new(Int32(10))
println(code[1])

println("\n=== Looking for foreigncalls ===")
for (i, stmt) in enumerate(code[1].code)
    if stmt isa Expr && stmt.head === :foreigncall
        println("\nStatement $i: $stmt")
        println("  args[1] (name): $(stmt.args[1])")
        if length(stmt.args) >= 2
            println("  args[2] (ret_type): $(stmt.args[2])")
        end
        if length(stmt.args) >= 7
            println("  args[7] (mem_type): $(stmt.args[7])")
            mem_type = stmt.args[7]
            if mem_type isa DataType
                println("    name: $(mem_type.name.name)")
                println("    parameters: $(mem_type.parameters)")
                if length(mem_type.parameters) >= 2
                    println("    elem_type (params[2]): $(mem_type.parameters[2])")
                end
            end
        end
    end
end

println("\n=== MemoryRef types ===")
for (i, stmt) in enumerate(code[1].code)
    if stmt isa Expr && stmt.head === :call
        func = stmt.args[1]
        func_name = if func isa GlobalRef
            func.name
        elseif func isa Symbol
            func
        else
            nothing
        end
        if func_name in (:memoryrefnew, Symbol("memoryrefnew"), :memoryrefset!, Symbol("memoryrefset!"))
            println("\nStatement $i: $func_name")
            for (j, arg) in enumerate(stmt.args[2:end])
                arg_type = code[1].ssavaluetypes[arg.id] 
                println("  arg $j: $(typeof(arg)) = $arg, type = $arg_type")
                if arg_type isa DataType
                    println("    name: $(arg_type.name.name)")
                end
            end
        end
    end
end
