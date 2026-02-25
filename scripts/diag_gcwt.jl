#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print -p $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")
    
    # Get the error offset
    errbuf = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    catch; end
    err = String(take!(errbuf))
    println("Error: $err")
    
    m = match(r"at offset (0x[0-9a-f]+)", err)
    if m !== nothing
        offset_str = m[1]
        println("\n--- Lines around offset $offset_str ---")
        for (i, line) in enumerate(lines)
            if contains(line, "(;@$(offset_str[3:end])")
                for j in max(1, i-10):min(length(lines), i+5)
                    println("L$j: $(strip(lines[j]))")
                end
                break
            end
        end
    end
    
    # Also print func signatures
    println("\n--- Func signatures ---")
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if startswith(stripped, "(func (;")
            println("L$i: $stripped")
        end
    end
    
    rm(tmpf; force=true)
end
main()
