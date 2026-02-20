#!/usr/bin/env julia
# diag_local62_decl.jl — find declaration of local 62 in func 15 of builtin_effects
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

# Use wasm-tools print (WAT format) and find func 15
wat_buf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_buf, stderr=devnull))
wat = String(take!(wat_buf))
wat_lines = split(wat, "\n")

# Count functions and get func 15 (0-indexed = 16th)
func_count = -1  # start at -1 since imports count as funcs 0, 1, ...
in_func15 = false
func15_start = 0
func15_end = 0
depth = 0

# imports are func 0 (Math.pow) → func 15 would be the 16th item
# In WAT, imports are listed first, then function definitions
# Count "(func" occurrences - both import and definition

# Find the 15th func definition (skip imports)
import_count = 0
for (i, l) in enumerate(wat_lines)
    if contains(l, "(func") && contains(l, "(import")
        import_count += 1
    end
end
println("Import functions: $import_count")

# Now find func definitions (non-import)
def_count = 0
for (i, l) in enumerate(wat_lines)
    if startswith(strip(l), "(func") && !contains(l, "(import")
        if def_count + import_count == 15
            # This is func index 15
            println("\n=== func 15 (0-indexed) starts at WAT line $i ===")
            # Show first 50 lines (local declarations)
            for j in i:min(i+60, length(wat_lines))
                println(lpad(j, 6), ": ", wat_lines[j])
                if j > i && strip(wat_lines[j]) == ")" && count('(', join(wat_lines[i:j], "")) == count(')', join(wat_lines[i:j], ""))
                    break
                end
            end
            break
        end
        def_count += 1
    end
end

rm(tmpf; force=true)
println("\nDone")
