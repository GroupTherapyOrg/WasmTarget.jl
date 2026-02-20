#!/usr/bin/env julia
# diag_builtin_effects_wat.jl — extract func 15 WAT from builtin_effects [111]
# func 15 is 0-indexed, so it's the 16th function in the WAT
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

println("Compiling builtin_effects [111]...")
bytes = compile(func, arg_types)
println("Compiled: $(length(bytes)) bytes")

tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Get WAT
println("Disassembling...")
wat_buf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_buf, stderr=devnull))
wat_text = String(take!(wat_buf))
wat_lines = split(wat_text, "\n")
println("WAT: $(length(wat_lines)) lines")

# Find the 16th function (func index 15 = 16th in 0-based)
# The WAT from wasm-tools print uses (func (;N;) format or $funcN style
func_count = 0
for (i, l) in enumerate(wat_lines)
    if startswith(strip(l), "(func")
        if func_count == 15
            println("\n=== func index 15 starts at WAT line $i ===")
            depth = 0
            for j in i:min(i+500, length(wat_lines))
                println(lpad(j, 5), ": ", wat_lines[j])
                depth += count('(', wat_lines[j]) - count(')', wat_lines[j])
                if j > i && depth <= 0
                    break
                end
            end
            break
        end
        func_count += 1
    end
end

println("\nTotal function count: $func_count+")

# Also validate and show exact error
err_buf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=err_buf, stdout=devnull))
    println("VALIDATES OK")
catch
    println("VALIDATE ERROR: ", String(take!(err_buf)))
end

rm(tmpf; force=true)
println("Done")
