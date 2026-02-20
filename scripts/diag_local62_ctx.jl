#!/usr/bin/env julia
# diag_local62_ctx.jl — check context around local 62 assignments
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

# Show context BEFORE 0x2021 (50 lines before)
println("=== Context 0x1fc0 to 0x2030 ===")
for (i, l) in enumerate(dump_lines)
    m = match(r"^\s+0x([0-9a-f]+)", l)
    if m !== nothing
        off = Base.parse(Int, "0x" * m.captures[1])
        if 0x1fc0 <= off <= 0x2030
            println(lpad(i, 6), ": ", l)
        end
    end
end

# Find the WAT (text) format and look at the local declarations
# The locals section in the binary dump appears right after the function header
# Let's find the func[15] entry in the dump
println("\n=== func[15] in dump ===")
for (i, l) in enumerate(dump_lines)
    if contains(l, "func[15]")
        for j in max(1, i-1):min(i+30, length(dump_lines))
            println(lpad(j, 6), ": ", dump_lines[j])
        end
        break
    end
end

rm(tmpf; force=true)
println("\nDone")
