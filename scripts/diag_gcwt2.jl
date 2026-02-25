#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")
    
    # Find type 67 definition
    println("--- Type definitions around 67 ---")
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if startswith(stripped, "(type (;6") || startswith(stripped, "(type (;7")
            println("L$i: $stripped")
        end
    end
    
    # Find global 27
    println("\n--- Global 27 ---")
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if contains(stripped, "(global (;27;)")
            println("L$i: $stripped")
        end
    end
    
    # Count total "struct.new 67" and "throw" instructions in func 1
    println("\n--- struct.new 67 and throw in func 1 ---")
    in_func1 = false
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if contains(stripped, "(func (;1;)")
            in_func1 = true
        end
        if in_func1 && i > 100 && startswith(stripped, "(func (;")
            break
        end
        if in_func1 && (contains(stripped, "struct.new 67") || contains(stripped, "throw "))
            println("L$i: $stripped")
        end
    end
    
    rm(tmpf; force=true)
end
main()
