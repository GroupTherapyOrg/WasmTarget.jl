#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax

sym = Symbol("adjust_macro_name!")
f = getfield(JuliaSyntax, sym)

# Compile and dump WAT
bytes = WasmTarget.compile(f, (Union{Expr, Symbol},))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Written $tmpf ($(length(bytes)) bytes)")

# Validate with more detail
run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=stderr, stdout=stdout), wait=false) |> wait

println()

# Print WAT
run(pipeline(`wasm-tools print $tmpf`, stdout=stdout), wait=false) |> wait
