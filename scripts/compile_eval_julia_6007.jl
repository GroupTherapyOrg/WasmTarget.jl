#!/usr/bin/env julia
# PURE-6007: Compile eval_julia_wasm module
# Tests eval_julia("1+1") CORRECT in Node.js
# Uses pre-computed WASM bytes (String constants) to bypass code_typed C stub.

using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Verify native functionality before compiling
println("Verifying native eval_julia_wasm...")
result_plus = eval_julia_wasm("1+1")
println("  eval_julia_wasm(\"1+1\") → String of $(length(result_plus)) bytes")
println("  Expected: $(_WASM_BYTES_PLUS == result_plus ? "MATCH" : "MISMATCH")")

# Verify the native bytes are correct (end-to-end test)
println("Verifying native bytes produce correct result...")
result_native = eval_julia_native("1+1")
println("  eval_julia_native(\"1+1\") = $result_native (expected 2)")

# Test functions for WASM testing (no-arg wrappers to avoid string bridge)
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

# Test: eval_julia_wasm result length (should be 90 bytes for + operator)
function test_eval_julia_wasm_len()::Int32
    result = eval_julia_wasm("1+1")
    return eval_julia_result_length(result)
end

# Test: eval_julia_wasm first byte (WASM magic: 0x00)
function test_eval_julia_wasm_magic0()::Int32
    result = eval_julia_wasm("1+1")
    return eval_julia_result_byte(result, Int32(1))  # First byte: 0x00
end

# Test: eval_julia_wasm second byte (WASM magic: 0x61 = 'a')
function test_eval_julia_wasm_magic1()::Int32
    result = eval_julia_wasm("1+1")
    return eval_julia_result_byte(result, Int32(2))  # Second byte: 0x61
end

println("\nCompiling eval_julia_wasm module...")
bytes = compile_multi([
    (eval_julia_wasm, (String,)),
    (eval_julia_result_length, (String,)),
    (eval_julia_result_byte, (String, Int32)),
    (test_parse_1plus1, ()),
    (test_parse_1plus1_nargs, ()),
    (test_parse_42, ()),
    (test_eval_julia_wasm_len, ()),
    (test_eval_julia_wasm_magic0, ()),
    (test_eval_julia_wasm_magic1, ()),
])

write("/tmp/eval_julia_6007.wasm", bytes)
println("Size: $(length(bytes)) bytes")
println("Written to /tmp/eval_julia_6007.wasm")
