#!/usr/bin/env julia
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    # Check what type 72 corresponds to in the type registry
    fn = eval(Meta.parse("WasmTarget.register_tuple_type!"))
    
    # Create a compilation context to see type mappings
    mod = WasmTarget.WasmModule()
    reg = WasmTarget.TypeRegistry()
    
    # Compile and check types
    bytes = WasmTarget.compile_multi([(fn, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}}))])
    
    # After compilation, check what's at type index 72 in the module
    # We need to access the module... let me check compile_multi output
    
    # Alternative: dump all struct types from type registry
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    
    watbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watbuf))
    wat = String(take!(watbuf))
    lines = split(wat, "\n")
    
    # Find the function that creates struct.new 72
    # Let's look at the FULL function to understand the context
    println("=== SEARCHING FOR struct.new 72 CONTEXT ===")
    func_start = 0
    for (i, line) in enumerate(lines)
        if startswith(strip(line), "(func ")
            func_start = i
        end
        if contains(line, "struct.new 72")
            # Print from func_start to struct.new + some more
            println("Function starts at line $func_start")
            # Print 30 lines before struct.new 72
            s = max(func_start, i-30)
            e = min(length(lines), i+5)
            for j in s:e
                marker = j == i ? " <<<" : ""
                println("$j: ", lines[j], marker)
            end
            println("---")
        end
    end
    
    rm(tmpf; force=true)
end
main()
