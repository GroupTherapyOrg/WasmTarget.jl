#!/usr/bin/env julia
# diag_find_local62_type.jl — find the declared type of local 62 in func 15
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

# Get WAT and find the 16th function definition (func index 15)
wat_buf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_buf, stderr=devnull))
wat_text = String(take!(wat_buf))
wat_lines = split(wat_text, "\n")

# Count function definitions (not imports)
# Imports come first, then definitions
# Count (import ... (func patterns
import_funcs = 0
for l in wat_lines
    if contains(l, "(import") && contains(l, "(func")
        import_funcs += 1
    end
end
println("Import functions: $import_funcs")

# Find the (func index 15 definition (= definition index 15 - import_funcs if imports < 15)
# Actually func index = position in all funcs (imports + defs), 0-based
# So func 15 = the (15 - import_funcs + 1)'th definition (1-based)
target_def = 15 - import_funcs + 1
println("Looking for definition #$target_def (func index 15)")

def_count = 0
in_target = false
depth = 0
func_start = 0

for (i, l) in enumerate(wat_lines)
    stripped = strip(l)
    if startswith(stripped, "(func") && !contains(l, "(import")
        def_count += 1
        if def_count == target_def
            in_target = true
            func_start = i
            depth = 0
            println("\n=== func index 15 (def #$target_def) starts at line $i ===")
        end
    end
    if in_target
        # Print only local declarations (first ~30 lines)
        if i - func_start <= 30
            println(lpad(i, 6), ": ", l)
        elseif i - func_start == 31
            println("  ... (rest of function omitted)")
        end
        # Track depth to know when function ends
        depth += count('(', l) - count(')', l)
        if i > func_start && depth <= 0
            in_target = false
            println("  (function ends at line $i)")
            break
        end
    end
end

# Also use the codegen internals to get local 62's Julia type
println("\n=== Local types from codegen ctx ===")

# We need to intercept the compilation context
# Hack: compile twice but instrument
println("Getting code_typed for builtin_effects...")
codeinfos = Core.Compiler.code_typed(func, Tuple{arg_types...}; optimize=true)
if !isempty(codeinfos)
    ci, rt = codeinfos[1]
    println("Return type: $rt")
    println("Num statements: $(length(ci.code))")
    println("SSA types (first 100):")
    for (i, (stmt, T)) in enumerate(zip(ci.code, ci.ssavaluetypes))
        if i <= 100
            println("  %$i :: $T")
        end
    end
end

rm(tmpf; force=true)
println("\nDone")
