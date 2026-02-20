#!/usr/bin/env julia
# diag_search_func15.jl — search for func 15 in WAT
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
mod_val = eval(Meta.parse(strip(parts[2])))
func_sym = Symbol(strip(parts[3]))
func_val = getfield(mod_val, func_sym)
arg_types = eval(Meta.parse(strip(parts[4])))
arg_types isa Tuple || (arg_types = (arg_types,))

bytes = compile(func_val, arg_types)
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

wat_buf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_buf, stderr=devnull))
wat_text = String(take!(wat_buf))
wat_lines = split(wat_text, "\n")
println("WAT: $(length(wat_lines)) lines")

# Find func with (;15;) index — try different patterns
for (i, l) in enumerate(wat_lines)
    if contains(l, ";15;") && contains(l, "func")
        println("Found at line $i: $l")
    end
end

rm(tmpf; force=true)
println("\nDone")
