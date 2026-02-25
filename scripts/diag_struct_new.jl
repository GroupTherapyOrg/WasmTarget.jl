#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")

    # Find func 1 boundaries
    func_starts = Int[]
    for (i, line) in enumerate(lines)
        if startswith(lstrip(line), "(func ")
            push!(func_starts, i)
        end
    end

    fstart = func_starts[1]
    fend = length(func_starts) > 1 ? func_starts[2]-1 : length(lines)

    # Find struct.new and conversion instructions in func 1
    for i in fstart:fend
        line = lines[i]
        if contains(line, "struct.new") || contains(line, "extern.convert") || contains(line, "any.convert")
            lo = max(fstart, i-5)
            hi = min(fend, i+5)
            for j in lo:hi
                marker = j == i ? " >>> " : "     "
                println("$marker$j: $(lines[j])")
            end
            println()
        end
    end

    rm(tmpf; force=true)
end
main()
