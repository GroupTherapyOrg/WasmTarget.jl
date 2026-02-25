#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Get validation error
errbuf = IOBuffer()
try Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull)) catch end
err = strip(String(take!(errbuf)))
println("ERROR: $err")
m = match(r"at offset (0x[0-9a-f]+)", err)
offset_hex = isnothing(m) ? "0x0" : m[1]
offset_int = parse(Int, offset_hex[3:end]; base=16)

# Get WAT, find func 6 signature and first few lines
outbuf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
wat = String(take!(outbuf))
lines = split(wat, "\n")

# Find all func declarations
println("\n=== FUNCTION TABLE ===")
for (i, line) in enumerate(lines)
    stripped = lstrip(line)
    if startswith(stripped, "(func ")
        println("line $i: $line")
    end
end

# Find the instruction at the error offset using dump
println("\n=== DUMP near offset $offset_hex ===")
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
        if lo > offset_int + 50
            break
        end
    end
end
if best > 0
    lo = max(1, best - 10)
    hi = min(length(dlines), best + 5)
    for j in lo:hi
        marker = j == best ? " >>> " : "     "
        println("$marker$(dlines[j])")
    end
end

rm(tmpf; force=true)
