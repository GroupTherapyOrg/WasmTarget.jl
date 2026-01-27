#!/usr/bin/env julia
# Test full interpreter compilation with all dependencies
#
# This script attempts to compile ALL interpreter functions together
# to produce a working interpreter.wasm module.

using Pkg
Pkg.activate(dirname(@__DIR__))

using WasmTarget

println("=" ^ 60)
println("TESTING FULL INTERPRETER COMPILATION")
println("=" ^ 60)

# ============================================================================
# Collect ALL interpreter functions
# ============================================================================

# Character classifiers
char_funcs = [
    (WasmTarget.is_digit, (Int32,)),
    (WasmTarget.is_alpha, (Int32,)),
    (WasmTarget.is_alnum, (Int32,)),
    (WasmTarget.is_whitespace, (Int32,)),
    (WasmTarget.is_newline, (Int32,)),
]

# Token constructors
token_funcs = [
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_error, (Int32,)),
    (WasmTarget.token_simple, (Int32, Int32, Int32)),
    (WasmTarget.token_int, (Int32, Int32, Int32)),
    (WasmTarget.token_float, (Float32, Int32, Int32)),
]

# Token list operations
tokenlist_funcs = [
    (WasmTarget.token_list_new, (Int32,)),
    (getfield(WasmTarget, Symbol("token_list_push!")), (WasmTarget.TokenList, WasmTarget.Token)),
    (WasmTarget.token_list_get, (WasmTarget.TokenList, Int32)),
]

# Lexer
lexer_funcs = [
    (WasmTarget.lexer_new, (String,)),
    (getfield(WasmTarget, Symbol("lexer_advance!")), (WasmTarget.Lexer,)),
    (WasmTarget.lexer_peek, (WasmTarget.Lexer,)),
    (WasmTarget.lexer_peek_at, (WasmTarget.Lexer, Int32)),
    (getfield(WasmTarget, Symbol("lexer_skip_whitespace!")), (WasmTarget.Lexer,)),
    (getfield(WasmTarget, Symbol("lexer_skip_comment!")), (WasmTarget.Lexer,)),
    (getfield(WasmTarget, Symbol("lexer_next_token!")), (WasmTarget.Lexer,)),
]

# Value constructors and helpers
value_funcs = [
    (WasmTarget.val_nothing, ()),
    (WasmTarget.val_int, (Int32,)),
    (WasmTarget.val_float, (Float32,)),
    (WasmTarget.val_bool, (Int32,)),
    (WasmTarget.val_string, (String,)),
    (WasmTarget.val_error, ()),
    (WasmTarget.val_func, (WasmTarget.ASTNode,)),
    (WasmTarget.val_is_truthy, (WasmTarget.Value,)),
    (WasmTarget.value_to_float, (WasmTarget.Value,)),
]

# Control flow
cf_funcs = [
    (WasmTarget.cf_normal, ()),
    (WasmTarget.cf_return, (WasmTarget.Value,)),
]

# Output buffer
output_funcs = [
    (WasmTarget.output_buffer_get, ()),
    (getfield(WasmTarget, Symbol("output_buffer_set!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_append!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_clear!")), ()),
]

# AST constructors (signatures match actual definitions in Parser.jl)
ast_funcs = [
    (WasmTarget.ast_error, ()),
    (WasmTarget.ast_int, (Int32,)),
    (WasmTarget.ast_float, (Float32,)),
    (WasmTarget.ast_bool, (Int32,)),
    (WasmTarget.ast_nothing, ()),
    (WasmTarget.ast_ident, (Int32, Int32)),
    (WasmTarget.ast_string, (Int32, Int32)),
    (WasmTarget.ast_binary, (Int32, WasmTarget.ASTNode, WasmTarget.ASTNode)),
    (WasmTarget.ast_unary, (Int32, WasmTarget.ASTNode)),
    (WasmTarget.ast_call, (WasmTarget.ASTNode, Vector{WasmTarget.ASTNode}, Int32)),
    (WasmTarget.ast_assign, (WasmTarget.ASTNode, WasmTarget.ASTNode)),
    (WasmTarget.ast_if, (WasmTarget.ASTNode, Vector{WasmTarget.ASTNode}, Int32, Union{WasmTarget.ASTNode, Nothing})),
    (WasmTarget.ast_while, (WasmTarget.ASTNode, Vector{WasmTarget.ASTNode}, Int32)),
    (WasmTarget.ast_for, (WasmTarget.ASTNode, WasmTarget.ASTNode, Vector{WasmTarget.ASTNode}, Int32)),
    (WasmTarget.ast_func, (Int32, Int32, Vector{WasmTarget.ASTNode}, Vector{WasmTarget.ASTNode}, Int32, Int32)),
    (WasmTarget.ast_return, (Union{WasmTarget.ASTNode, Nothing},)),
    (WasmTarget.ast_block, (Vector{WasmTarget.ASTNode}, Int32)),
    (WasmTarget.ast_program, (Vector{WasmTarget.ASTNode}, Int32)),
]

# Binary operations
binary_funcs = [
    (WasmTarget.eval_binary_int_int, (Int32, Int32, Int32)),
    (WasmTarget.eval_binary_float_float, (Int32, Float32, Float32)),
    (WasmTarget.eval_equality, (WasmTarget.Value, WasmTarget.Value)),
    (WasmTarget.eval_unary, (Int32, WasmTarget.Value)),
]

# Environment (actual signatures from Evaluator.jl)
env_funcs = [
    (WasmTarget.env_new, (Int32,)),
    (WasmTarget.env_get, (WasmTarget.Env, String)),
    (getfield(WasmTarget, Symbol("env_set!")), (WasmTarget.Env, String, WasmTarget.Value)),
    (getfield(WasmTarget, Symbol("env_push_scope!")), (WasmTarget.Env,)),
    (getfield(WasmTarget, Symbol("env_pop_scope!")), (WasmTarget.Env,)),
]

# String operations (from Runtime)
string_funcs = [
    (WasmTarget.str_eq, (String, String)),
    (WasmTarget.str_len, (String,)),
    (WasmTarget.str_char, (String, Int32)),
    (WasmTarget.str_substr, (String, Int32, Int32)),
    (WasmTarget.digit_to_str, (Int32,)),
    (WasmTarget.int_to_string, (Int32,)),
]

# ============================================================================
# Test Phase 1: Core primitives (no cross-references)
# ============================================================================
println("\n[Phase 1] Core primitives...")

phase1 = vcat(char_funcs, token_funcs, value_funcs, cf_funcs, output_funcs, string_funcs)

try
    wasm = WasmTarget.compile_multi(phase1)
    println("  ✓ Phase 1: $(length(phase1)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Phase 1: $e")
end

# ============================================================================
# Test Phase 2: Structures with Vector fields
# ============================================================================
println("\n[Phase 2] Structures with Vector fields...")

phase2 = vcat(phase1, tokenlist_funcs, lexer_funcs, ast_funcs, env_funcs)

try
    wasm = WasmTarget.compile_multi(phase2)
    println("  ✓ Phase 2: $(length(phase2)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Phase 2: $e")
end

# ============================================================================
# Test Phase 3: Binary operations (depend on value helpers)
# ============================================================================
println("\n[Phase 3] Binary operations...")

phase3 = vcat(phase2, binary_funcs)

try
    wasm = WasmTarget.compile_multi(phase3)
    println("  ✓ Phase 3: $(length(phase3)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Phase 3: $e")
end

# ============================================================================
# Test Phase 4: Tokenize (all lexer functions)
# ============================================================================
println("\n[Phase 4] Tokenize...")

try
    # Try to add tokenize to the list
    phase4 = vcat(phase3, [(WasmTarget.tokenize, (String,))])
    wasm = WasmTarget.compile_multi(phase4)
    println("  ✓ Phase 4: $(length(phase4)) functions, $(length(wasm)) bytes")
catch e
    println("  ✗ Phase 4 (tokenize): $e")
end

println("\n" * "=" ^ 60)
println("SUMMARY")
println("=" ^ 60)
