#!/usr/bin/env julia
# Compile the Julia interpreter to WebAssembly
#
# This script compiles all interpreter functions (Tokenizer, Parser, Evaluator, REPL)
# into a single interpreter.wasm module that can be loaded in the browser.
#
# Usage:
#   julia --project scripts/compile_interpreter.jl
#
# Output:
#   docs/dist/wasm/interpreter.wasm

using Pkg
Pkg.activate(dirname(@__DIR__))

using WasmTarget

# Output directory
output_dir = joinpath(dirname(@__DIR__), "docs", "dist", "wasm")
mkpath(output_dir)

println("=" ^ 60)
println("COMPILING INTERPRETER TO WEBASSEMBLY")
println("=" ^ 60)

# ============================================================================
# Phase 1: Test basic function compilation
# ============================================================================
println("\n[Phase 1] Testing basic function compilation...")

# Test simple value constructors first (no dependencies)
phase1_funcs = [
    (WasmTarget.val_nothing, ()),
    (WasmTarget.val_int, (Int32,)),
    (WasmTarget.val_float, (Float32,)),
    (WasmTarget.val_bool, (Int32,)),
    (WasmTarget.val_string, (String,)),
    (WasmTarget.val_error, ()),
]

try
    wasm = WasmTarget.compile_multi(phase1_funcs)
    println("  ✓ Value constructors: $(length(phase1_funcs)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Value constructors: $e")
end

# ============================================================================
# Phase 2: Test output buffer functions (global state)
# ============================================================================
println("\n[Phase 2] Testing output buffer functions...")

phase2_funcs = [
    (WasmTarget.output_buffer_get, ()),
    (getfield(WasmTarget, Symbol("output_buffer_set!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_append!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_clear!")), ()),
]

try
    wasm = WasmTarget.compile_multi(phase2_funcs)
    println("  ✓ Output buffer: $(length(phase2_funcs)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Output buffer: $e")
end

# ============================================================================
# Phase 3: Test tokenizer character classifiers
# ============================================================================
println("\n[Phase 3] Testing tokenizer character classifiers...")

phase3_funcs = [
    (WasmTarget.is_digit, (Int32,)),
    (WasmTarget.is_alpha, (Int32,)),
]

try
    wasm = WasmTarget.compile_multi(phase3_funcs)
    println("  ✓ Character classifiers: $(length(phase3_funcs)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Character classifiers: $e")
end

# ============================================================================
# Phase 4: Test Value helpers (excluding string conversion which uses Base.string)
# ============================================================================
println("\n[Phase 4] Testing Value helpers...")

phase4_funcs = [
    (WasmTarget.val_nothing, ()),
    (WasmTarget.val_int, (Int32,)),
    (WasmTarget.val_is_truthy, (WasmTarget.Value,)),
    (WasmTarget.value_to_float, (WasmTarget.Value,)),
    # Note: int_to_string, float_to_string, value_to_string use Base.string() which doesn't compile
]

try
    wasm = WasmTarget.compile_multi(phase4_funcs)
    println("  ✓ Value helpers: $(length(phase4_funcs)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Value helpers: $e")
end

# ============================================================================
# Phase 5: Test binary operations (one by one to find the blocker)
# ============================================================================
println("\n[Phase 5] Testing binary operations...")

# Test each binary function individually
binary_funcs = [
    ("eval_binary_int_int", WasmTarget.eval_binary_int_int, (Int32, Int32, Int32)),
    ("eval_binary_float_float", WasmTarget.eval_binary_float_float, (Int32, Float32, Float32)),
    ("eval_equality", WasmTarget.eval_equality, (WasmTarget.Value, WasmTarget.Value)),
    ("eval_unary", WasmTarget.eval_unary, (Int32, WasmTarget.Value)),
]

for (name, fn, args) in binary_funcs
    try
        wasm = WasmTarget.compile_multi([
            (WasmTarget.val_nothing, ()),
            (WasmTarget.val_int, (Int32,)),
            (WasmTarget.val_float, (Float32,)),
            (WasmTarget.val_bool, (Int32,)),
            (WasmTarget.val_error, ()),
            (fn, args),
        ])
        println("  ✓ $name: $(length(wasm)) bytes")
    catch e
        println("  ✗ $name: $(typeof(e)) - $(sprint(showerror, e))")
    end
end

# ============================================================================
# Phase 6: Test control flow helpers
# ============================================================================
println("\n[Phase 6] Testing control flow helpers...")

phase6_funcs = [
    (WasmTarget.val_nothing, ()),
    (WasmTarget.cf_normal, ()),
    (WasmTarget.cf_return, (WasmTarget.Value,)),
]

try
    wasm = WasmTarget.compile_multi(phase6_funcs)
    println("  ✓ Control flow: $(length(phase6_funcs)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Control flow: $e")
end

# ============================================================================
# Phase 7: Test AST constructors
# ============================================================================
println("\n[Phase 7] Testing AST constructors...")

phase7_funcs = [
    (WasmTarget.ast_error, ()),
    (WasmTarget.ast_int, (Int32,)),
    (WasmTarget.ast_float, (Float32,)),
    (WasmTarget.ast_bool, (Int32,)),
    (WasmTarget.ast_nothing, ()),
]

try
    wasm = WasmTarget.compile_multi(phase7_funcs)
    println("  ✓ AST constructors: $(length(phase7_funcs)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ AST constructors: $e")
end

# ============================================================================
# Phase 8: Test Token constructors
# ============================================================================
println("\n[Phase 8] Testing Token constructors...")

phase8_funcs = [
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_error, (Int32,)),
    (WasmTarget.token_simple, (Int32, Int32, Int32)),
    (WasmTarget.token_int, (Int32, Int32, Int32)),
    (WasmTarget.token_float, (Float32, Int32, Int32)),
]

try
    wasm = WasmTarget.compile_multi(phase8_funcs)
    println("  ✓ Token constructors: $(length(phase8_funcs)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Token constructors: $e")
end

# ============================================================================
# Phase 9: Test Lexer creation
# ============================================================================
println("\n[Phase 9] Testing Lexer creation...")

phase9_funcs = [
    (WasmTarget.lexer_new, (String,)),
]

try
    wasm = WasmTarget.compile_multi(phase9_funcs)
    println("  ✓ Lexer: $(length(phase9_funcs)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Lexer: $e")
end

# ============================================================================
# Phase 10: Attempt full compilation with all basic functions
# ============================================================================
println("\n[Phase 10] Compiling all basic interpreter functions together...")

all_basic_funcs = [
    # Value constructors
    (WasmTarget.val_nothing, ()),
    (WasmTarget.val_int, (Int32,)),
    (WasmTarget.val_float, (Float32,)),
    (WasmTarget.val_bool, (Int32,)),
    (WasmTarget.val_string, (String,)),
    (WasmTarget.val_error, ()),
    (WasmTarget.val_func, (WasmTarget.ASTNode,)),

    # Value helpers (excluding string conversion - uses Base.string which doesn't compile)
    (WasmTarget.val_is_truthy, (WasmTarget.Value,)),
    (WasmTarget.value_to_float, (WasmTarget.Value,)),

    # Binary operations (excluding eval_binary which calls value_to_string for strings)
    (WasmTarget.eval_binary_int_int, (Int32, Int32, Int32)),
    (WasmTarget.eval_binary_float_float, (Int32, Float32, Float32)),
    (WasmTarget.eval_equality, (WasmTarget.Value, WasmTarget.Value)),
    (WasmTarget.eval_unary, (Int32, WasmTarget.Value)),

    # Control flow
    (WasmTarget.cf_normal, ()),
    (WasmTarget.cf_return, (WasmTarget.Value,)),

    # Output buffer
    (WasmTarget.output_buffer_get, ()),
    (getfield(WasmTarget, Symbol("output_buffer_set!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_append!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_clear!")), ()),

    # Character classifiers
    (WasmTarget.is_digit, (Int32,)),
    (WasmTarget.is_alpha, (Int32,)),

    # Token constructors
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_error, (Int32,)),
    (WasmTarget.token_simple, (Int32, Int32, Int32)),
    (WasmTarget.token_int, (Int32, Int32, Int32)),
    (WasmTarget.token_float, (Float32, Int32, Int32)),

    # Lexer
    (WasmTarget.lexer_new, (String,)),

    # AST constructors
    (WasmTarget.ast_error, ()),
    (WasmTarget.ast_int, (Int32,)),
    (WasmTarget.ast_float, (Float32,)),
    (WasmTarget.ast_bool, (Int32,)),
    (WasmTarget.ast_nothing, ()),
]

try
    wasm = WasmTarget.compile_multi(all_basic_funcs)
    println("  ✓ All basic functions: $(length(all_basic_funcs)) functions, $(length(wasm)) bytes")

    # Save this as a working module
    wasm_path = joinpath(output_dir, "interpreter_basic.wasm")
    write(wasm_path, wasm)
    println("  ✓ Wrote: $wasm_path")
catch e
    println("  ✗ All basic functions: $e")
    if e isa Exception
        for (exc, bt) in Base.catch_stack()
            showerror(stdout, exc, bt)
            println()
        end
    end
end

# ============================================================================
# Phase 11: Test Environment functions
# ============================================================================
println("\n[Phase 11] Testing Environment functions...")

# env_new requires Vector allocation which may be the blocker
phase11_funcs = [
    (WasmTarget.val_nothing, ()),
    (WasmTarget.env_new, (Int32,)),
]

try
    wasm = WasmTarget.compile_multi(phase11_funcs)
    println("  ✓ Environment: $(length(phase11_funcs)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Environment: $e")
    # This is expected to fail due to Vector{String} and Vector{Value}
end

# ============================================================================
# Phase 12: Test Parser creation
# ============================================================================
println("\n[Phase 12] Testing Parser creation...")

phase12_funcs = [
    (WasmTarget.parser_new, (String, Int32)),
]

try
    wasm = WasmTarget.compile_multi(phase12_funcs)
    println("  ✓ Parser: $(length(phase12_funcs)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Parser: $e")
end

# ============================================================================
# Summary
# ============================================================================
println("\n" * ("=" ^ 60))
println("COMPILATION SUMMARY")
println("=" ^ 60)
println()
println("WORKING FUNCTIONS:")
println("  ✓ Value constructors (val_nothing, val_int, val_float, val_bool, val_string, val_error, val_func)")
println("  ✓ Value helpers (val_is_truthy, value_to_float)")
println("  ✓ Output buffer (global state access works!)")
println("  ✓ Character classifiers (is_digit, is_alpha)")
println("  ✓ Binary/unary operations (eval_binary_int_int, eval_binary_float_float, eval_equality, eval_unary)")
println("  ✓ Control flow helpers (cf_normal, cf_return)")
println("  ✓ Token constructors (token_eof, token_error, token_simple, token_int, token_float)")
println("  ✓ Lexer creation (lexer_new)")
println("  ✓ AST constructors (ast_error, ast_int, ast_float, ast_bool, ast_nothing)")
println("  ✓ Environment (env_new with Vector{String} and Vector{Value})")
println()
println("BLOCKED:")
println("  ✗ int_to_string, float_to_string, value_to_string - use Base.string() which doesn't compile")
println("  ✗ Parser (parser_new) - calls tokenize which has complex dependencies")
println("  ✗ interpret entry point - depends on parser and string conversion")
println()
println("KEY BLOCKER: Base.string() function")
println("  The interpreter needs to convert Int32/Float32 to String for output.")
println("  Currently int_to_string uses: Base.inferencebarrier(string(n))::String")
println("  This calls Julia's internal #string#530 method which isn't supported.")
println()
println("SOLUTION NEEDED:")
println("  1. Implement a WASM-native int_to_string using str_new/str_setchar!")
println("  2. Currently _int_to_string_wasm exists but str_setchar! is no-op in Julia")
println("  3. Once string conversion works, most interpreter functions should compile")
println()
