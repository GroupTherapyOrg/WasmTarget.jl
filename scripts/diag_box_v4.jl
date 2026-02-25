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
    
    # Print all lines in func 1 that contain "call" or "extern" or "local.get 2"
    in_func1 = false
    func1_end = 0
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if contains(stripped, "(func (;1;)")
            in_func1 = true
        end
        if in_func1 && (contains(stripped, "call ") || contains(stripped, "extern") || 
            contains(stripped, "struct_new") || contains(stripped, "struct.new") ||
            contains(stripped, "ref.i31") || contains(stripped, "any.convert") ||
            contains(stripped, "any_convert"))
            println("L$i: $stripped")
        end
        # End of func 1 (next func starts)
        if in_func1 && i > 93 && startswith(stripped, "(func ")
            break
        end
    end
    
    rm(tmpf; force=true)
end
main()
