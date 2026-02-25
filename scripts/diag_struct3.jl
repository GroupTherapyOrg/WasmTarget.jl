#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    # Get WAT
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")
    println("Total WAT lines: $(length(lines))")

    # Find all func declarations
    for (i, line) in enumerate(lines)
        stripped = lstrip(line)
        if startswith(stripped, "(func ")
            println("$i: $line")
        end
    end

    # The error is at offset 0x3ef9. Search with broader patterns
    println("\n--- Searching for offset patterns ---")
    for (i, line) in enumerate(lines)
        if contains(line, "@0x3e") && contains(line, "f")
            println("$i: $line")
        end
    end

    # Look for the FIRST occurrence of externref in func body
    println("\n--- First 20 externref mentions ---")
    ecount = 0
    for (i, line) in enumerate(lines)
        if contains(line, "externref")
            ecount += 1
            println("$i: $line")
            if ecount >= 20
                break
            end
        end
    end

    rm(tmpf; force=true)
end
main()
