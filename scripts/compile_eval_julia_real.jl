#!/usr/bin/env julia
# PURE-6007: Compile real eval_julia pipeline to WASM
# Uses WasmInterpreter (typeinf_frame) — NOT pre-computed bytes.
# 4/4 CORRECT natively verified before compiling.

using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Helper functions to extract bytes from WasmGC Vector{UInt8} result
function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end

function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

# Parse-only test functions (no typeinf or codegen)
function test_parse_1plus1()::Int32
    expr = JuliaSyntax.parsestmt(Expr, "1+1")
    return expr isa Expr && expr.head === :call ? Int32(1) : Int32(0)
end

function test_parse_1plus1_nargs()::Int32
    expr = JuliaSyntax.parsestmt(Expr, "1+1")
    return expr isa Expr ? Int32(length(expr.args)) : Int32(-1)
end

function test_parse_42()::Int32
    expr = JuliaSyntax.parsestmt(Expr, "42")
    return expr isa Integer ? Int32(1) : Int32(0)
end

println("=== PURE-6007: Compile real eval_julia pipeline to WASM ===")
println()

println("[Phase 1] Verifying native correctness first (4/4 must pass)...")
all_pass = true
for (code, expected) in [("1+1", 2), ("2+3", 5), ("10-3", 7), ("6*7", 42)]
    try
        result = eval_julia_native(code)
        ok = result == expected
        println("  eval_julia_native(\"$code\") = $result $(ok ? "CORRECT" : "WRONG")")
        all_pass = all_pass && ok
    catch e
        println("  eval_julia_native(\"$code\") = ERROR: $(sprint(showerror, e))")
        all_pass = false
    end
end
if !all_pass
    println("\nFAIL: Native verification failed. Not compiling to WASM.")
    exit(1)
end
println("  4/4 CORRECT natively")
println()

println("[Phase 2] Compiling to WASM...")
println("  (This compiles eval_julia_to_bytes + all dependencies to WASM)")
println()

funcs_to_compile = [
    (eval_julia_to_bytes, (String,)),
    (eval_julia_result_length, (Vector{UInt8},)),
    (eval_julia_result_byte, (Vector{UInt8}, Int32)),
    (test_parse_1plus1, ()),
    (test_parse_1plus1_nargs, ()),
    (test_parse_42, ()),
]

try
    bytes = compile_multi(funcs_to_compile)
    write("/tmp/eval_julia_6007.wasm", bytes)
    println("  Size: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB)")
    println("  Written to /tmp/eval_julia_6007.wasm")
    println()
    println("[Phase 3] Validate with wasm-tools...")
    validate_result = run(`wasm-tools validate /tmp/eval_julia_6007.wasm`)
    println("  VALIDATES")
catch e
    println("  COMPILE ERROR: ", sprint(showerror, e))
    exit(1)
end
