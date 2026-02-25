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
    
    # Print lines 820-880 (around the calls)
    println("--- func 1 lines 820-880 ---")
    for i in 820:min(880, length(lines))
        println("L$i: $(strip(lines[i]))")
    end
    
    # Also print func signatures again to see param types of func 2 and func 3
    println("\n--- func signatures ---")
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if startswith(stripped, "(func (;")
            println("L$i: $stripped")
        end
    end
    
    rm(tmpf; force=true)
end
main()
