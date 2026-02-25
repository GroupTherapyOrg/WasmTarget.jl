#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    # Get dump at offset 0x70d0
    offset_int = 0x70d0
    dumpbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dumpbuf))
    dump = String(take!(dumpbuf))
    dlines = split(dump, "\n")
    best = 0
    for (i, line) in enumerate(dlines)
        lm = match(r"^\s*(0x[0-9a-f]+)", line)
        if !isnothing(lm)
            lo = parse(Int, lm[1][3:end]; base=16)
            if lo <= offset_int
                best = i
            end
            if lo > offset_int + 100
                break
            end
        end
    end
    if best > 0
        lo = max(1, best - 20)
        hi = min(length(dlines), best + 10)
        for j in lo:hi
            marker = j == best ? " >>> " : "     "
            println("$marker$(dlines[j])")
        end
    end

    rm(tmpf; force=true)
end
main()
