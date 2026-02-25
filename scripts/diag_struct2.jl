#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    # Get detailed validation error
    errbuf = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools validate -v --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    catch
    end
    err = String(take!(errbuf))
    println("ERROR: $err")

    # Get WAT, find func $func_1, dump first 100 lines
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")

    # Find start of func_1 and dump context
    in_func = false
    count = 0
    for (i, line) in enumerate(lines)
        stripped = lstrip(line)
        if startswith(stripped, "(func \$func_1 ")
            in_func = true
        end
        if in_func
            count += 1
            println("$i: $line")
            if count > 150
                println("... truncated")
                break
            end
        end
    end

    rm(tmpf; force=true)
end
main()
