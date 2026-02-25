#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Get WAT
outbuf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
wat = String(take!(outbuf))
lines = split(wat, "\n")

# Find func 6 (line 7166) and dump first 100 lines
println("=== FUNC 6 (first 100 lines) ===")
start_line = 7166
for i in start_line:min(start_line+100, length(lines))
    println("$i: $(lines[i])")
end

rm(tmpf; force=true)
