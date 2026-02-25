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
    
    # Print ALL array.set lines in func 1
    println("--- func 1: all array.set lines ---")
    for i in 93:881
        stripped = strip(lines[i])
        if contains(stripped, "array.set")
            println("L$i: $stripped")
        end
    end
    
    # Now find array.set 14 and show context 
    println("\n--- Context around array.set 14 ---")
    for i in 93:881
        stripped = strip(lines[i])
        if stripped == "array.set 14"
            start_i = max(93, i - 15)
            for j in start_i:i
                println("L$j: $(strip(lines[j]))")
            end
            println("---")
        end
    end
    
    rm(tmpf; force=true)
end
main()
