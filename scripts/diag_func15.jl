#!/usr/bin/env julia
# diag_func15.jl — find (func (;15;) in WAT and check local 62 type
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

# Find (func (;15;) exactly
func15_line = 0
for (i, l) in enumerate(wat_lines)
    if contains(l, "(func (;15;)")
        func15_line = i
        break
    end
end

println("(func (;15;) found at WAT line: $func15_line")

if func15_line > 0
    # Print header (locals declaration line)
    println("\n=== func (;15;) header and locals ===")
    for i in func15_line:min(func15_line+3, length(wat_lines))
        println(lpad(i, 6), ": ", wat_lines[i])
    end

    # Parse the local declarations on line func15_line + 1
    if func15_line + 1 <= length(wat_lines)
        local_line = wat_lines[func15_line + 1]
        if contains(local_line, "(local")
            println("\n=== Local declarations ===")
            println(local_line)

            # Parse all types from the (local ...) declaration
            # Pattern: (local type1 type2 ...)
            m = match(r"\(local\s+(.*?)\)\s*$", local_line)
            if m !== nothing
                types_str = m.captures[1]
                # Parse individual types - handle compound types like (ref null N)
                types = String[]
                pos = 1
                while pos <= length(types_str)
                    if types_str[pos] == '('
                        # Find matching closing paren
                        depth = 0
                        start = pos
                        while pos <= length(types_str)
                            if types_str[pos] == '('
                                depth += 1
                            elseif types_str[pos] == ')'
                                depth -= 1
                                if depth == 0
                                    push!(types, types_str[start:pos])
                                    pos += 1
                                    break
                                end
                            end
                            pos += 1
                        end
                    elseif types_str[pos] == ' '
                        pos += 1
                    else
                        # simple type like i32, i64, f32, f64, externref, etc.
                        end_pos = findfirst(c -> c == ' ' || c == '(', types_str[pos:end])
                        if end_pos === nothing
                            push!(types, types_str[pos:end])
                            break
                        else
                            push!(types, types_str[pos:pos+end_pos-2])
                            pos += end_pos - 1
                        end
                    end
                end

                # Function has 1 param, so locals start at index 1
                n_params = 1
                println("n_params: $n_params")
                println("n_locals: $(length(types))")
                println("")

                # Local 62 = index 62 → param takes 0, so local 62 = types[62 - n_params + 1] = types[62]
                target_local = 62
                local_type_idx = target_local - n_params + 1  # 1-based in types array
                if local_type_idx >= 1 && local_type_idx <= length(types)
                    println("local $target_local type: $(types[local_type_idx])")
                end

                # Print range around local 62
                println("\nLocals 58-70:")
                for i in 58:70
                    idx = i - n_params + 1
                    if idx >= 1 && idx <= length(types)
                        println("  local $i: $(types[idx])")
                    end
                end
            end
        else
            println("No local declaration on line $(func15_line + 1)")
            println("  Line content: ", local_line)
        end
    end
end

rm(tmpf; force=true)
println("\nDone")
