#!/usr/bin/env julia
# diag_local62_simple.jl — simple version
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
func_sym = Symbol(strip(parts[3]))
func_val = getfield(mod, func_sym)
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
println("func 15 at line 12165")

# Print lines 12165 to 12220 to see the function header and locals
println("\n=== Lines 12165-12250 ===")
for i in 12165:min(12250, length(wat_lines))
    println(lpad(i, 6), ": ", wat_lines[i])
end

rm(tmpf; force=true)
println("\nDone")
