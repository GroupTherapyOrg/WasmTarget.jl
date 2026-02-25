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
    
    # Print lines 310-350 (around first array.get 14)
    println("--- func 1 lines 310-360 ---")
    for i in 310:min(360, length(lines))
        println("L$i: $(strip(lines[i]))")
    end
    
    # Print lines 660-710 (around second array.get 14)
    println("\n--- func 1 lines 660-710 ---")
    for i in 660:min(710, length(lines))
        println("L$i: $(strip(lines[i]))")
    end
    
    rm(tmpf; force=true)
end
main()
