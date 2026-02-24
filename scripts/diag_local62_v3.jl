#!/usr/bin/env julia
# Trace which SSA becomes local 62 using debug logging in codegen

ENV["WASMTARGET_DEBUG_LOCALS"] = "1"

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

const Compiler = Core.Compiler
PL = Compiler.PartialsLattice{Compiler.ConstsLattice}

println("Compiling builtin_effects(PartialsLattice) with debug logging...")
flush(stdout)
bytes = compile(Compiler.builtin_effects, (PL, Core.Builtin, Vector{Any}, Any))
println("Compiled: $(length(bytes)) bytes")

# Validate
tmpf = joinpath(tempdir(), "be_v3.wasm")
write(tmpf, bytes)
errbuf = IOBuffer()
ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    ok = true
catch
end
if ok
    println("VALIDATES!")
else
    println("VALIDATE_ERROR: $(String(take!(errbuf)))")
end
println("Done.")
