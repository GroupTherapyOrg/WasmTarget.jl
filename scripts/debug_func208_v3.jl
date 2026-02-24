#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget, JuliaSyntax

f = getfield(JuliaSyntax, Symbol("adjust_macro_name!"))
bytes = WasmTarget.compile(f, (Union{Expr, Symbol},))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Size: $(length(bytes)) bytes")

# Validate
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    println("VALIDATES")
catch
    println("VALIDATE_ERROR: ", String(take!(errbuf)))
end

# Print WAT
println("\n=== WAT ===")
buf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=buf))
println(String(take!(buf)))
