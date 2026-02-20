#!/usr/bin/env julia
# diag_local62_source.jl — find what's stored in local 62 at 0x5db5
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
all_lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), all_lines)
line111 = data_lines[findfirst(l -> startswith(l, "111 |"), data_lines)]
parts = split(line111, " | ")
mod = eval(Meta.parse(strip(parts[2])))
func = getfield(mod, Symbol(strip(parts[3])))
arg_types = eval(Meta.parse(strip(parts[4])))
arg_types isa Tuple || (arg_types = (arg_types,))

bytes = compile(func, arg_types)
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

dump_buf = IOBuffer()
Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_buf, stderr=devnull))
dump_text = String(take!(dump_buf))
dump_lines = split(dump_text, "\n")

# Show 30 lines before 0x5db5 (last local_set 62 before the error)
println("=== Context around 0x5db5 (last local_set 62 before error) ===")
for (i, l) in enumerate(dump_lines)
    m = match(r"^\s+0x([0-9a-f]+)", l)
    if m !== nothing
        off = Base.parse(Int, "0x" * m.captures[1])
        if 0x5d90 <= off <= 0x5dc0
            println(lpad(i, 6), ": ", l)
        end
    end
end

# Show 0x3672 (first local_set 62 near the region)
println("\n=== Context around 0x3672 (local_set 62) ===")
for (i, l) in enumerate(dump_lines)
    m = match(r"^\s+0x([0-9a-f]+)", l)
    if m !== nothing
        off = Base.parse(Int, "0x" * m.captures[1])
        if 0x3650 <= off <= 0x3690
            println(lpad(i, 6), ": ", l)
        end
    end
end

# Show 0x2021 (first local_set 62)
println("\n=== Context around 0x2021 (first local_set 62) ===")
for (i, l) in enumerate(dump_lines)
    m = match(r"^\s+0x([0-9a-f]+)", l)
    if m !== nothing
        off = Base.parse(Int, "0x" * m.captures[1])
        if 0x2000 <= off <= 0x2070
            println(lpad(i, 6), ": ", l)
        end
    end
end

rm(tmpf; force=true)
println("\nDone")
