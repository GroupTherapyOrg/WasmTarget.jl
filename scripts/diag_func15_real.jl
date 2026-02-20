#!/usr/bin/env julia
# diag_func15_real.jl — get local 62 type from func (;15;)
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

# func (;15;) is at line 11908
# Show header and locals
start = 11908
println("=== func (;15;) header and locals ===")
for i in start:min(start+5, length(wat_lines))
    println(lpad(i, 6), ": ", wat_lines[i])
end

# Parse local types
local_line = wat_lines[start + 1]
println("\n=== Local declaration line ===")
println(local_line)

# Parse individual types - handle compound types like (ref null N)
types_str_m = match(r"\(local\s+(.*)\)\s*$", local_line)
if types_str_m !== nothing
    types_str = types_str_m.captures[1]
    # Parse types handling nested parens
    types = String[]
    pos = 1
    while pos <= length(types_str)
        ch = types_str[pos]
        if ch == ' '
            pos += 1
        elseif ch == '('
            depth = 0
            start_pos = pos
            while pos <= length(types_str)
                if types_str[pos] == '('
                    depth += 1
                elseif types_str[pos] == ')'
                    depth -= 1
                    if depth == 0
                        push!(types, types_str[start_pos:pos])
                        pos += 1
                        break
                    end
                end
                pos += 1
            end
        else
            # simple type
            end_pos = nothing
            for q in pos:length(types_str)
                if types_str[q] == ' ' || types_str[q] == '('
                    end_pos = q - 1
                    break
                end
            end
            if end_pos === nothing
                push!(types, types_str[pos:end])
                break
            else
                push!(types, types_str[pos:end_pos])
                pos = end_pos + 1
            end
        end
    end

    n_params = 1  # 1 param
    println("\nn_params: $n_params")
    println("n_locals: $(length(types))")

    # local 62 = types[62 - n_params + 1] = types[62] (1-based)
    println("\nLocals 58-70:")
    for i in 58:70
        idx = i - n_params + 1
        if idx >= 1 && idx <= length(types)
            println("  local $i (types[$idx]): $(types[idx])")
        end
    end
else
    println("Could not match local declarations")
end

rm(tmpf; force=true)
println("\nDone")
