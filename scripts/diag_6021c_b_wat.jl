#!/usr/bin/env julia
# diag_6021c_b_wat.jl — get WAT for func_15 in builtin_effects [111]
# to understand the actual error at offset 0x7dc6
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

# Get full WAT
println("Disassembling...")
wat_buf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_buf, stderr=devnull))
wat_text = String(take!(wat_buf))
wat_lines = split(wat_text, "\n")
println("WAT: $(length(wat_lines)) lines")

# Find func_15 (the one that fails validation)
func15_line = 0
for (i, l) in enumerate(wat_lines)
    if contains(l, "(func") && contains(l, "\$func_15 ")
        func15_line = i
        break
    end
end

if func15_line == 0
    # Try alternate pattern
    for (i, l) in enumerate(wat_lines)
        if contains(l, "(func \$func_15")
            func15_line = i
            break
        end
    end
end

println("func_15 starts at WAT line: $func15_line")

if func15_line > 0
    # Print func_15 body (up to 200 lines or until next func)
    depth = 0
    for i in func15_line:min(func15_line+300, length(wat_lines))
        l = wat_lines[i]
        println(lpad(i, 5), ": ", l)
        # Count parens to find function end
        depth += count('(', l) - count(')', l)
        if i > func15_line && depth <= 0
            break
        end
    end
else
    println("func_15 not found — printing first 100 lines of WAT")
    for (i, l) in enumerate(wat_lines[1:min(100, end)])
        println(lpad(i, 5), ": ", l)
    end
end

rm(tmpf; force=true)
println("\nDone")
