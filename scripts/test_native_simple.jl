#!/usr/bin/env julia
# Test _wasm_simple_call_expr natively
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== Native test of _wasm_simple_call_expr ===")

for expr_str in ["1+1", "2+3", "10-3", "6*7"]
    ps = JuliaSyntax.ParseStream(Vector{UInt8}(codeunits(expr_str)))
    JuliaSyntax.parse!(ps; rule=:statement)
    expr = _wasm_simple_call_expr(ps)
    println("  $expr_str → $expr (args=$(expr.args))")
end
println()

println("=== Full pipeline test ===")
for (code, expected) in [("1+1", 2), ("2+3", 5), ("10-3", 7), ("6*7", 42)]
    result = eval_julia_native(code)
    status = result == expected ? "CORRECT" : "WRONG (got $result)"
    println("  eval_julia_native(\"$code\") = $result — $status")
end
