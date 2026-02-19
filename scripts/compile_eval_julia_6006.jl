#!/usr/bin/env julia
# PURE-6006: Compile eval_julia module with parse test functions
using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Test function: just parse "1+1" and verify it's an Expr with :call head
function test_parse_1plus1()::Int32
    expr = JuliaSyntax.parsestmt(Expr, "1+1")
    return expr isa Expr && expr.head === :call ? Int32(1) : Int32(0)
end

# Test function: parse and count args (should be 3: :+, 1, 1)
function test_parse_1plus1_nargs()::Int32
    expr = JuliaSyntax.parsestmt(Expr, "1+1")
    return expr isa Expr ? Int32(length(expr.args)) : Int32(-1)
end

# Test: parse "42" - should be an integer literal
function test_parse_42()::Int32
    expr = JuliaSyntax.parsestmt(Expr, "42")
    return expr isa Integer ? Int32(1) : Int32(0)
end

println("Compiling eval_julia module with test functions...")
bytes = compile_multi([
    (eval_julia_to_bytes, (String,)),
    (test_parse_1plus1, ()),
    (test_parse_1plus1_nargs, ()),
    (test_parse_42, ()),
])
write("/tmp/eval_julia_6006.wasm", bytes)
println("Size: $(length(bytes)) bytes")
println("Written to /tmp/eval_julia_6006.wasm")
