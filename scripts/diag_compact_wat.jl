#!/usr/bin/env julia
# diag_compact_wat.jl — Show WAT for compact! [121] func_4
# This is the function with VALIDATE_ERROR: "expected (ref null $type) but nothing on stack"
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@eval const Compiler = Core.Compiler
@eval const IRCode = Core.Compiler.IRCode

f = Compiler.compact!
arg_types = (IRCode, Bool)
println("Compiling compact! $(arg_types)...")
bytes = compile(f, arg_types)
println("Compiled: $(length(bytes)) bytes")

tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Get WAT
wat_out = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_out))
wat_str = String(take!(wat_out))
wat_lines = split(wat_str, "\n")

func_starts = Int[]
for (i, line) in enumerate(wat_lines)
    if !isnothing(match(r"^\s*\(func\s", line))
        push!(func_starts, i)
    end
end
println("Total funcs: $(length(func_starts))")

# func_4 is 0-indexed; func_starts[5] = index 4 (0-based)
if length(func_starts) >= 5
    f4_start = func_starts[5]
    f4_end = length(func_starts) >= 6 ? func_starts[6]-1 : length(wat_lines)
    println("func_4 at lines $f4_start-$f4_end ($(f4_end-f4_start) lines)")
    println()
    for i in f4_start:min(f4_start+300, f4_end)
        println(wat_lines[i])
    end
else
    println("Not enough funcs found. Showing all:")
    for line in wat_lines[1:min(100, end)]
        println(line)
    end
end

rm(tmpf; force=true)
