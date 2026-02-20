#!/usr/bin/env julia
# diag_wat_around12146.jl — see WAT context around local.get 62 at line 12146
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

# Show WAT around line 12146 (where local.get 62 appears in func ;15;)
println("=== WAT context around line 12146 ===")
# Find all lines in func (;15;) (starts at 11908) that have local.get 62 or i64.mul
# and look at context
target_line = 12146
for i in (target_line - 30):(target_line + 30)
    if i >= 1 && i <= length(wat_lines)
        marker = (i == target_line) ? ">>>" : "   "
        println("$marker $(lpad(i, 6)): $(wat_lines[i])")
    end
end

rm(tmpf; force=true)
println("\nDone")
