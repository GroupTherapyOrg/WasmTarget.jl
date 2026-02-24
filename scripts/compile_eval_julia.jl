# compile_eval_julia.jl — Compile eval_julia_to_bytes and validate
using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("Compiling eval_julia_to_bytes(String)...")
t0 = time()
bytes = WasmTarget.compile_multi([(eval_julia_to_bytes, (String,))])
elapsed = round(time() - t0, digits=1)
println("Compiled: $(length(bytes)) bytes in $(elapsed)s")

outf = joinpath(@__DIR__, "..", "output", "eval_julia.wasm")
mkpath(dirname(outf))
write(outf, bytes)
println("Saved to: $outf")
