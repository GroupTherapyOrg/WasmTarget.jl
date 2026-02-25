#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

bytes = WasmTarget.compile_multi([(WasmTarget.get_numeric_box_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, WasmTarget.NumType))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("$(length(bytes)) bytes")

# Write WAT to temp file and use shell tools to extract func_1
outbuf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
wat = String(take!(outbuf))
watf = tmpf * ".wat"
write(watf, wat)

# Use grep to show exports and func_1 signature
println("\n--- Exports ---")
for line in split(wat, "\n")
    if contains(line, "(export ")
        println(strip(line))
    end
end

# Find func_1 and print it using range matching
println("\n--- func_1 (first 100 lines) ---")
lines = split(wat, "\n")
f1_start = findfirst(l -> contains(l, "(func (;1;)"), lines)
if f1_start !== nothing
    f1_end = min(f1_start + 100, length(lines))
    for i in f1_start:f1_end
        println("L$i: $(lines[i])")
    end
end

# Validate
println()
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    println("VALIDATES")
catch
    println(String(take!(errbuf)))
end

rm(tmpf; force=true)
rm(watf; force=true)
