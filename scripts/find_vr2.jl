#!/usr/bin/env julia
# find_vr2.jl — show WAT lines 1620-1680 (before/after 0xe8c)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), lines)
target_line = first(filter(l -> contains(l, "apply_type_nothrow"), data_lines))

parts = split(target_line, " | ")
func_name = strip(parts[3])
mod_name = strip(parts[2])
arg_types_str = strip(parts[4])
mod_val = eval(Meta.parse(mod_name))
func = getfield(mod_val, Symbol(func_name))
arg_types = let t = eval(Meta.parse(arg_types_str)); t isa Tuple ? t : (t,) end

bytes = compile(func, arg_types)
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Show lines 1610-1700 of the dump
dump_buf = IOBuffer()
Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_buf))
dump_content = String(take!(dump_buf))
dump_lines = split(dump_content, '\n')
println("Total dump lines: $(length(dump_lines))")
println("Lines 1610-1700:")
for (i, l) in enumerate(dump_lines[1610:min(1700, end)])
    println("$(1609+i): $l")
end
