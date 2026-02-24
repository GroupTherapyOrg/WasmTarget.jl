#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget, JuliaSyntax

f = getfield(JuliaSyntax, Symbol("adjust_macro_name!"))
bytes = WasmTarget.compile(f, (Union{Expr, Symbol},))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Size: $(length(bytes)) bytes, file: $tmpf")

# Validate
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    println("VALIDATES")
catch
    println("VALIDATE_ERROR: ", String(take!(errbuf)))
end

# Dump
buf = IOBuffer()
Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=buf))
dump_text = String(take!(buf))
# Find offset 0x2f8
for line in split(dump_text, '\n')
    m = match(r"0x([0-9a-f]+)", line)
    if m !== nothing
        offset = parse(Int, m.captures[1]; base=16)
        if offset >= 0x2e0 && offset <= 0x310
            println(line)
        end
    end
end
