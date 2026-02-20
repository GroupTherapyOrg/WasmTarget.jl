#!/usr/bin/env julia
# diag_local62_decls.jl — find func 15's local declarations in WAT
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

# Use wasm-tools print and extract locals from func 15
wat_buf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_buf, stderr=devnull))
wat_text = String(take!(wat_buf))
wat_lines = split(wat_text, "\n")

# Find all function starts and track which one is func index 15
# Count: import + def order
func_idx = -1
func15_range = (0, 0)

# Track open function brackets
func_starts = Int[]  # line indices where (func starts
for (i, l) in enumerate(wat_lines)
    stripped = strip(l)
    if startswith(stripped, "(func")
        push!(func_starts, i)
    end
end
println("Total (func entries: $(length(func_starts))")

# Func index 15 (0-based) = func_starts[16] (1-based)
if length(func_starts) >= 16
    start_line = func_starts[16]  # 0-indexed func 15 = 16th entry
    println("func index 15 starts at WAT line: $start_line")

    # Find the end of this function (matching closing paren)
    depth = 0
    end_line = start_line
    for j in start_line:min(start_line + 50000, length(wat_lines))
        depth += count('(', wat_lines[j]) - count(')', wat_lines[j])
        if j > start_line && depth <= 0
            end_line = j
            break
        end
    end
    println("func index 15 ends at WAT line: $end_line")

    # Print the (local ...) declarations (first 100 lines of function body)
    println("\n=== Local declarations of func 15 ===")
    local_count = 0
    for j in start_line:min(start_line + 200, end_line)
        l = wat_lines[j]
        if contains(l, "(local")
            println(lpad(j, 6), ": ", l)
            local_count += 1
        elseif local_count > 0 && !contains(l, "(local")
            # After local declarations, stop
            if !contains(l, "(param") && !contains(l, "(result") && !contains(l, "(func")
                println("  [locals end, $(local_count) local declaration lines]")
                break
            end
        end
    end

    # Count locals to figure out the index of each type
    println("\n=== Counting locals to find local 62 type ===")
    all_local_types = String[]
    for j in start_line:end_line
        l = wat_lines[j]
        # Match (local i32) or (local i64) etc or (local $name type)
        m = match(r"\(local\s+([^)]+)\)", l)
        if m !== nothing
            # Could be multiple types: (local i32 i64)
            type_str = strip(m.captures[1])
            # Remove named locals if present (\$name type)
            # Split by whitespace
            parts_l = split(type_str)
            for p in parts_l
                if p in ["i32", "i64", "f32", "f64"] || startswith(p, "externref") || startswith(p, "(ref") || startswith(p, "anyref") || startswith(p, "structref") || startswith(p, "arrayref")
                    push!(all_local_types, p)
                elseif !startswith(p, "\$")  # skip named
                    push!(all_local_types, p)
                end
            end
        end
    end

    # Params count (need to know offset)
    param_count = 0
    for j in start_line:min(start_line + 5, end_line)
        l = wat_lines[j]
        ms = collect(eachmatch(r"\(param\s+([^)]+)\)", l))
        for m in ms
            param_types = split(strip(m.captures[1]))
            for p in param_types
                if p != "\$" && !startswith(p, "\$")
                    param_count += 1
                end
            end
        end
    end
    println("Parameter count: $param_count")
    println("Total locals declared: $(length(all_local_types))")
    if length(all_local_types) >= 63
        local62_type = all_local_types[63]  # 0-indexed: local 62 = index 63 in 1-based
        println("local 62 type: $local62_type")
        println("local 61 type: $(all_local_types[62])")
        println("local 63 type: $(all_local_types[64])")
        println("local 64 type: $(all_local_types[65])")
        println("Locals 58-70:")
        for (i, t) in enumerate(all_local_types[59:min(71, end)])
            println("  local $(57+i): $t")
        end
    end
end

rm(tmpf; force=true)
println("\nDone")
