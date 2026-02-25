#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.get_numeric_box_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, WasmTarget.NumType))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    
    # Try wasm-tools print with byte offsets
    outbuf = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools print --print-offsets $tmpf`, stdout=outbuf))
    catch
        # fallback
        outbuf = IOBuffer()
        Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    end
    wat = String(take!(outbuf))
    lines = split(wat, "\n")
    
    # Search for lines containing "0x9f" near the offset 0x9ff
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if contains(stripped, "@09f") || contains(stripped, "@0a0") || contains(stripped, "0x9f")
            println("L$i: $stripped")
        end
    end
    
    rm(tmpf; force=true)
end
main()
