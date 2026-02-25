#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# 5 functions with "expected subtype of anyref, found externref"
failing = [
    (WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), "0x1658"),
    (WasmTarget.register_tuple_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType), "0x27bd"),
    (WasmTarget.register_closure_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType), "0x280e"),
    (WasmTarget.register_matrix_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), "0x1367"),
    (WasmTarget.get_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), "0xa3b0"),
]

for (func, argtypes, offset_hex) in failing
    fname = nameof(func)
    println("\n========== $fname (offset $offset_hex) ==========")
    try
        bytes = WasmTarget.compile_multi([(func, argtypes)])
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        offset_int = parse(Int, offset_hex[3:end]; base=16)

        # Get binary dump around the error offset
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
            lo = max(1, best - 15)
            hi = min(length(dlines), best + 5)
            for j in lo:hi
                marker = j == best ? " >>> " : "     "
                println("$marker$(dlines[j])")
            end
        end

        rm(tmpf; force=true)
    catch e
        println("  COMPILE_ERROR: $e")
    end
end
