#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.get_numeric_box_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, WasmTarget.NumType))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")
    
    # Find the line at offset 0x9ff - look for instructions near that area
    # Print func_1 with line numbers to find what instruction is at offset 0x9ff
    println("--- func_1 first 60 lines ---")
    in_func1 = false
    count = 0
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if contains(stripped, "(func \$func_1")
            in_func1 = true
        end
        if in_func1 && count < 60
            println("L$i: $stripped")
            count += 1
        end
    end
    
    # Also show all function signatures  
    println("\n--- Function signatures ---")
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if startswith(stripped, "(func ")
            println("L$i: $stripped")
        end
    end
    
    # Also show all type definitions
    println("\n--- Type definitions (first 30) ---")
    type_count = 0
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if startswith(stripped, "(type ") && type_count < 30
            println("L$i: $stripped")
            type_count += 1
        end
    end
    
    rm(tmpf; force=true)
end
main()
