#!/usr/bin/env julia
# Recompile parsestmt.wasm and validate
using WasmTarget, JuliaSyntax

parse_expr_string(s::String) = JuliaSyntax.parsestmt(Expr, s)

println("Compiling parse_expr_string(String)...")
bytes = compile(parse_expr_string, (String,))
outf = joinpath(@__DIR__, "parsestmt_new.wasm")
write(outf, bytes)
println("Compiled $(length(bytes)) bytes → $outf")

# Validate
result = Base.run(pipeline(`wasm-tools validate --features=gc $outf`; stderr=stderr); wait=true)
if result.exitcode == 0
    println("VALIDATES!")
else
    println("FAILS validation")
    # Get error details
    err = read(pipeline(`wasm-tools validate --features=gc $outf`; stderr=stderr), String)
    println(err)
end
