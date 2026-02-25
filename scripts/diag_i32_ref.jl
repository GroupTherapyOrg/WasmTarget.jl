#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function dump_at(func, argtypes, offset_hex)
    fname = nameof(func)
    println("\n========== $fname (offset $offset_hex) ==========")
    bytes = WasmTarget.compile_multi([(func, argtypes)])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    offset_int = parse(Int, offset_hex[3:end]; base=16)

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
        lo = max(1, best - 25)
        hi = min(length(dlines), best + 10)
        for j in lo:hi
            marker = j == best ? " >>> " : "     "
            println("$marker$(dlines[j])")
        end
    end
    rm(tmpf; force=true)
end

dump_at(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType), "0x8997")
dump_at(WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), "0xfafd")
