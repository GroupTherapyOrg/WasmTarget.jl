#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function dump_at_offset(tmpf, offset_hex)
    offset_int = parse(Int, offset_hex[3:end]; base=16)
    dumpbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dumpbuf))
    dump_text = String(take!(dumpbuf))
    lines = split(dump_text, '\n')
    best_i = 0
    for (i, line) in enumerate(lines)
        lm = match(r"^\s*(0x[0-9a-f]+)", line)
        if !isnothing(lm)
            line_off = parse(Int, lm[1][3:end]; base=16)
            if line_off <= offset_int
                best_i = i
            end
            if line_off > offset_int + 100
                break
            end
        end
    end
    if best_i > 0
        lo = max(1, best_i - 10)
        hi = min(length(lines), best_i + 5)
        for j in lo:hi
            marker = j == best_i ? " >>> " : "     "
            println("$marker$(lines[j])")
        end
    end
end

# register_struct_type!
println("=== register_struct_type! ===")
bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
dump_at_offset(tmpf, "0x585f")
rm(tmpf; force=true)

# get_concrete_wasm_type
println("\n=== get_concrete_wasm_type ===")
bytes = WasmTarget.compile_multi([(WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
dump_at_offset(tmpf, "0x9e5b")
rm(tmpf; force=true)
