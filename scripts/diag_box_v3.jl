#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.get_numeric_box_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, WasmTarget.NumType))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    
    # Get WAT
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")
    
    # func 1 starts at line 93 per our earlier check. Print a window.
    println("--- func 1 (lines 93-250) ---")
    for i in 93:min(250, length(lines))
        println("L$i: $(strip(lines[i]))")
    end
    
    rm(tmpf; force=true)
end
main()
