#!/usr/bin/env julia
# diag_b_offset.jl — analyze error at offset 0x7dc6 in builtin_effects [111]
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

# First validate to get exact error
err_buf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=err_buf, stdout=devnull))
    println("VALIDATES OK")
catch
    println("VALIDATE ERROR: ", String(take!(err_buf)))
end

# dump around 0x7dc6
target_offset = 0x7dc6
dump_buf = IOBuffer()
Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_buf, stderr=devnull))
dump_text = String(take!(dump_buf))
dump_lines = split(dump_text, "\n")
println("Dump: $(length(dump_lines)) lines")

# Find lines near 0x7dc6
println("\n=== Dump lines near offset 0x7dc6 ===")
for (i, l) in enumerate(dump_lines)
    # Look for offset in range [0x7db0, 0x7de0]
    m = match(r"^\s+0x([0-9a-f]+)", l)
    if m !== nothing
        off = Base.parse(Int, "0x" * m.captures[1])
        if 0x7db0 <= off <= 0x7de0
            println(lpad(i, 6), ": ", l)
        end
    end
end

# Also find the func 15 boundary in the dump
println("\n=== func 15 boundary in dump ===")
func_count = 0
for (i, l) in enumerate(dump_lines)
    if contains(l, "func[") && contains(l, "]:")
        if func_count >= 13 && func_count <= 18
            println(lpad(i, 6), ": [func #$func_count] $l")
        end
        func_count += 1
    end
end

rm(tmpf; force=true)
println("\nDone")
