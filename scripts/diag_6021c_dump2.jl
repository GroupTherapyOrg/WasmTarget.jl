#!/usr/bin/env julia
# Targeted dump analysis for early_inline_special_case
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)
@isdefined(SourceFile) || (@eval const SourceFile = JuliaSyntax.SourceFile)
@isdefined(InternalCodeCache) || (@eval const InternalCodeCache = Core.Compiler.InternalCodeCache)
@isdefined(WorldRange) || (@eval const WorldRange = Core.Compiler.WorldRange)
@isdefined(InferenceResult) || (@eval const InferenceResult = Core.Compiler.InferenceResult)
@isdefined(IRCode) || (@eval const IRCode = Core.Compiler.IRCode)

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
all_lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), all_lines)

line142 = data_lines[findfirst(l -> startswith(l, "142 |"), data_lines)]
parts = split(line142, " | ")
func = getfield(eval(Meta.parse(strip(parts[2]))), Symbol(strip(parts[3])))
arg_types = eval(Meta.parse(strip(parts[4])))
bytes = compile(func, arg_types)
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Bytes: $(length(bytes))")

dump_buf = IOBuffer()
Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_buf))
dump = String(take!(dump_buf))
dump_lines = split(dump, "\n")
println("Dump: $(length(dump_lines)) lines")
println("First 5 lines:")
for (i, l) in enumerate(dump_lines[1:5])
    println("  $l")
end

# wasm-tools dump shows offsets like: " 0x0000093b | 20 00    | local.get 0"
# or " 0x935 |..."
# Let's find lines near 0x935
target = 0x935
lines_in_range = filter(i -> begin
    m = match(r"0x([0-9a-f]+)\s*\|", dump_lines[i])
    if !isnothing(m)
        off = Base.parse(Int, "0x" * m.captures[1])
        abs(off - target) < 100
    else
        false
    end
end, 1:length(dump_lines))

println("\nLines near offset 0x935 (±100): $(length(lines_in_range))")
for i in lines_in_range
    println("  $i: $(dump_lines[i])")
end
