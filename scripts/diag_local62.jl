#!/usr/bin/env julia
# diag_local62.jl — find where local 62 is set in builtin_effects [111]
# Error: local_get 62 pushes externref but i64_mul expects i64
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

# Find all local_set/local_get for local 62 and surrounding context
println("=== All references to local 62 ===")
for (i, l) in enumerate(dump_lines)
    if contains(l, "local_index:62") || contains(l, "local_index:63")
        println(lpad(i, 6), ": ", l)
    end
end

println("\n=== Local declarations (first 120 locals) ===")
in_func15 = false
func_count = 0
for (i, l) in enumerate(dump_lines)
    if contains(l, "func[")
        if func_count == 15
            println("\nfunc 15 boundary at line $i")
        end
        func_count += 1
    end
end

println("\n=== Context around offset 0x7dc2 (where local_get 62 is) ===")
# 30 lines before 0x7dc6
for (i, l) in enumerate(dump_lines)
    m = match(r"^\s+0x([0-9a-f]+)", l)
    if m !== nothing
        off = Base.parse(Int, "0x" * m.captures[1])
        if 0x7d80 <= off <= 0x7dc8
            println(lpad(i, 6), ": ", l)
        end
    end
end

rm(tmpf; force=true)
println("\nDone")
