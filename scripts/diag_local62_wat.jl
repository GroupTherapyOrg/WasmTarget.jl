#!/usr/bin/env julia
# diag_local62_wat.jl — find local type in WAT format
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

# Get WAT
wat_buf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_buf, stderr=devnull))
wat_text = String(take!(wat_buf))
wat_lines = split(wat_text, "\n")
println("WAT lines: $(length(wat_lines))")

# Find lines with "local 0x3e" (= local 62) in WAT
# wasm-tools uses $local62 or local 62 notation
println("\n=== WAT lines with local 62 references ===")
for (i, l) in enumerate(wat_lines)
    if contains(l, "local 62") || contains(l, "local.get 62") || contains(l, "local.set 62") || contains(l, "\$local62")
        println(lpad(i, 6), ": ", l)
    end
end

# Also find what LOCAL DECLARATIONS look like in the WAT
# Look for lines that start with "(local" or have "(local " pattern
println("\n=== WAT local declarations (near func 15) ===")
func15_def = 0
for (i, l) in enumerate(wat_lines)
    if startswith(strip(l), "(func") && !contains(l, "(import")
        func15_def += 1
        if func15_def == 15  # 15th non-import function = func index 14 + 1 import = func 15
            println("Found func def #$func15_def at line $i")
            # Print local declarations (next ~50 lines)
            for j in i:min(i+100, length(wat_lines))
                println(lpad(j, 6), ": ", wat_lines[j])
                if j > i && startswith(strip(wat_lines[j]), "(local") == false &&
                   !contains(wat_lines[j], "(param") && !contains(wat_lines[j], "(result") &&
                   !contains(wat_lines[j], "(func") && strip(wat_lines[j]) != "" &&
                   !startswith(strip(wat_lines[j]), "(local")
                    # Once we're past the declarations, stop
                    if j > i + 5
                        break
                    end
                end
            end
            break
        end
    end
end

rm(tmpf; force=true)
println("\nDone")
