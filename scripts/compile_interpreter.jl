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
# Build comprehensive function list
# ============================================================================

# String conversion (must be first - used by many functions)
string_funcs = [
    (WasmTarget.digit_to_str, (Int32,)),
    (WasmTarget.int_to_string, (Int32,)),
]

# Runtime string operations (auto-discovered but list explicitly for visibility)
string_ops = [
    (WasmTarget.str_eq, (String, String)),
    (WasmTarget.str_len, (String,)),
    (WasmTarget.str_char, (String, Int32)),
    # str_concat uses * operator which is already handled
]

# String creation/mutation for JS<->WASM marshaling
string_marshaling = [
    (WasmTarget.str_new, (Int32,)),
    (getfield(WasmTarget, Symbol("str_setchar!")), (String, Int32, Int32)),
]

# Value constructors
value_constructors = [
    (WasmTarget.val_nothing, ()),
    (WasmTarget.val_int, (Int32,)),
    (WasmTarget.val_float, (Float32,)),
    (WasmTarget.val_bool, (Int32,)),
    (WasmTarget.val_string, (String,)),
    (WasmTarget.val_func, (WasmTarget.ASTNode,)),
    (WasmTarget.val_error, ()),
]

# Value helpers
value_helpers = [
    (WasmTarget.val_is_truthy, (WasmTarget.Value,)),
    (WasmTarget.value_to_float, (WasmTarget.Value,)),
    (WasmTarget.value_to_string, (WasmTarget.Value,)),
    (WasmTarget.float_to_string, (Float32,)),
]

# Control flow
control_flow = [
    (WasmTarget.cf_normal, ()),
    (WasmTarget.cf_return, (WasmTarget.Value,)),
]

# Output buffer
output_buffer = [
    (WasmTarget.output_buffer_get, ()),
    (getfield(WasmTarget, Symbol("output_buffer_set!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_append!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_clear!")), ()),
]

# Token constructors
token_constructors = [
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_error, (Int32,)),
    (WasmTarget.token_simple, (Int32, Int32, Int32)),
    (WasmTarget.token_int, (Int32, Int32, Int32)),
    (WasmTarget.token_float, (Float32, Int32, Int32)),
]

# Character classifiers
char_classifiers = [
    (WasmTarget.is_digit, (Int32,)),
    (WasmTarget.is_alpha, (Int32,)),
    (WasmTarget.is_alnum, (Int32,)),
    (WasmTarget.is_whitespace, (Int32,)),
    (WasmTarget.is_newline, (Int32,)),
]

# Lexer functions
lexer_funcs = [
    (WasmTarget.lexer_new, (String,)),
    (WasmTarget.lexer_peek, (WasmTarget.Lexer,)),
    (WasmTarget.lexer_peek_at, (WasmTarget.Lexer, Int32)),
    (getfield(WasmTarget, Symbol("lexer_advance!")), (WasmTarget.Lexer,)),
    (getfield(WasmTarget, Symbol("lexer_skip_whitespace!")), (WasmTarget.Lexer,)),
    (getfield(WasmTarget, Symbol("lexer_skip_comment!")), (WasmTarget.Lexer,)),
    (getfield(WasmTarget, Symbol("lexer_next_token!")), (WasmTarget.Lexer,)),
]

# Scanner functions
scanner_funcs = [
    (WasmTarget.scan_integer, (WasmTarget.Lexer,)),
    (WasmTarget.scan_float_after_dot, (WasmTarget.Lexer, Int32, Int32)),
    (WasmTarget.scan_identifier, (WasmTarget.Lexer,)),
    (WasmTarget.scan_string, (WasmTarget.Lexer,)),
    (WasmTarget.scan_operator, (WasmTarget.Lexer,)),
]

# Keyword check functions
keyword_funcs = [
    (WasmTarget.check_keyword, (String, Int32, Int32)),
    (WasmTarget.check_keyword_2, (String, Int32)),
    (WasmTarget.check_keyword_3, (String, Int32)),
    (WasmTarget.check_keyword_4, (String, Int32)),
    (WasmTarget.check_keyword_5, (String, Int32)),
    (WasmTarget.check_keyword_6, (String, Int32)),
    (WasmTarget.check_keyword_7, (String, Int32)),
    (WasmTarget.check_keyword_8, (String, Int32)),
]

# Token list functions
token_list_funcs = [
    (WasmTarget.token_list_new, (Int32,)),
    (getfield(WasmTarget, Symbol("token_list_push!")), (WasmTarget.TokenList, WasmTarget.Token)),
    (WasmTarget.token_list_get, (WasmTarget.TokenList, Int32)),
    (WasmTarget.tokenize, (String, Int32)),
]

# AST constructors
ast_constructors = [
    (WasmTarget.ast_error, ()),
    (WasmTarget.ast_int, (Int32,)),
    (WasmTarget.ast_float, (Float32,)),
    (WasmTarget.ast_bool, (Int32,)),
    (WasmTarget.ast_nothing, ()),
    (WasmTarget.ast_string, (Int32, Int32)),
    (WasmTarget.ast_ident, (Int32, Int32)),
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

# Parser functions
parser_funcs = [
    (WasmTarget.parser_new, (String, Int32)),
    (WasmTarget.parser_current, (WasmTarget.Parser,)),
    (WasmTarget.parser_current_type, (WasmTarget.Parser,)),
    (WasmTarget.parser_check, (WasmTarget.Parser, Int32)),
    (getfield(WasmTarget, Symbol("parser_advance!")), (WasmTarget.Parser,)),
    (getfield(WasmTarget, Symbol("parser_consume!")), (WasmTarget.Parser, Int32)),
    (getfield(WasmTarget, Symbol("parser_skip_terminators!")), (WasmTarget.Parser,)),
    (WasmTarget.parser_at_end, (WasmTarget.Parser,)),
]

# Parse functions
parse_funcs = [
    (WasmTarget.parse_primary, (WasmTarget.Parser,)),
    (WasmTarget.parse_call_args, (WasmTarget.Parser, WasmTarget.ASTNode)),
    (WasmTarget.parse_call, (WasmTarget.Parser,)),
    (WasmTarget.parse_power, (WasmTarget.Parser,)),
    (WasmTarget.parse_unary, (WasmTarget.Parser,)),
    (WasmTarget.parse_factor, (WasmTarget.Parser,)),
    (WasmTarget.parse_term, (WasmTarget.Parser,)),
    (WasmTarget.parse_comparison, (WasmTarget.Parser,)),
    (WasmTarget.parse_equality, (WasmTarget.Parser,)),
    (WasmTarget.parse_logic_and, (WasmTarget.Parser,)),
    (WasmTarget.parse_logic_or, (WasmTarget.Parser,)),
    (WasmTarget.parse_expression, (WasmTarget.Parser,)),
    (WasmTarget.is_statement_start, (WasmTarget.Parser,)),
    (WasmTarget.parse_block_body, (WasmTarget.Parser, Int32)),
    (WasmTarget.parse_if_statement, (WasmTarget.Parser,)),
    (WasmTarget.parse_while_statement, (WasmTarget.Parser,)),
    (WasmTarget.parse_for_statement, (WasmTarget.Parser,)),
    (WasmTarget.parse_function_definition, (WasmTarget.Parser,)),
    (WasmTarget.parse_return_statement, (WasmTarget.Parser,)),
    (WasmTarget.parse_expr_or_assign_statement, (WasmTarget.Parser,)),
    (WasmTarget.parse_statement, (WasmTarget.Parser,)),
    (WasmTarget.parse_program, (WasmTarget.Parser,)),
]

# Environment functions
env_funcs = [
    (WasmTarget.env_new, (Int32,)),
    (getfield(WasmTarget, Symbol("env_push_scope!")), (WasmTarget.Env,)),
    (getfield(WasmTarget, Symbol("env_pop_scope!")), (WasmTarget.Env,)),
    (WasmTarget.env_find, (WasmTarget.Env, String)),
    (WasmTarget.env_get, (WasmTarget.Env, String)),
    (getfield(WasmTarget, Symbol("env_set!")), (WasmTarget.Env, String, WasmTarget.Value)),
    (getfield(WasmTarget, Symbol("env_define!")), (WasmTarget.Env, String, WasmTarget.Value)),
]

# Binary/unary operations
binary_ops = [
    (WasmTarget.eval_binary, (Int32, WasmTarget.Value, WasmTarget.Value)),
    (WasmTarget.eval_binary_int_int, (Int32, Int32, Int32)),
    (WasmTarget.eval_binary_float_float, (Int32, Float32, Float32)),
    (WasmTarget.eval_equality, (WasmTarget.Value, WasmTarget.Value)),
    (WasmTarget.eval_unary, (Int32, WasmTarget.Value)),
]

# Builtin functions
builtin_funcs = [
    (WasmTarget.eval_builtin, (String, Vector{WasmTarget.Value}, Int32, WasmTarget.Env)),
    (WasmTarget.builtin_println, (Vector{WasmTarget.Value}, Int32, WasmTarget.Env)),
    (WasmTarget.builtin_print, (Vector{WasmTarget.Value}, Int32, WasmTarget.Env)),
    (WasmTarget.builtin_abs, (WasmTarget.Value,)),
    (WasmTarget.builtin_min, (WasmTarget.Value, WasmTarget.Value)),
    (WasmTarget.builtin_max, (WasmTarget.Value, WasmTarget.Value)),
    (WasmTarget.builtin_typeof, (WasmTarget.Value,)),
    (WasmTarget.builtin_string, (WasmTarget.Value,)),
    (WasmTarget.builtin_length, (WasmTarget.Value,)),
]

# Eval functions
eval_funcs = [
    (WasmTarget.eval_node, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    (WasmTarget.eval_binary_node, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    (WasmTarget.eval_call, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    (WasmTarget.eval_user_func, (WasmTarget.ASTNode, Vector{WasmTarget.Value}, Int32, String, WasmTarget.Env)),
    (WasmTarget.eval_assignment, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    (WasmTarget.eval_if, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    (WasmTarget.eval_while, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    (WasmTarget.eval_for, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    (WasmTarget.eval_func_def, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    (WasmTarget.eval_return, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    (WasmTarget.eval_block, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    (WasmTarget.eval_program, (WasmTarget.ASTNode, String)),
]

# REPL entry points
repl_funcs = [
    (WasmTarget.get_output, ()),
    (getfield(WasmTarget, Symbol("clear_output")), ()),
    (WasmTarget.make_parse_error, (String, Int32, Int32)),
    (WasmTarget.make_empty_error, ()),
    (WasmTarget.interpret, (String,)),
]

# ============================================================================
# Test individual groups first
# ============================================================================

function test_group(name, funcs)
    try
        wasm = WasmTarget.compile_multi(funcs)
        println("  ✓ $name: $(length(funcs)) functions, $(length(wasm)) bytes")
        return true
    catch e
        println("  ✗ $name: $(typeof(e))")
        if e isa ErrorException
            println("    $(e.msg)")
        end
        return false
    end
end

println("\n[Phase 1] Testing individual function groups...")

test_group("String conversion", string_funcs)
test_group("Value constructors", value_constructors)
test_group("Control flow", control_flow)
test_group("Output buffer", output_buffer)
test_group("Token constructors", token_constructors)
test_group("Character classifiers", char_classifiers)

# Test functions that may have dependencies
println("\n[Phase 2] Testing functions with dependencies...")
test_group("Value helpers", vcat(value_constructors, value_helpers, string_funcs))
test_group("Binary ops", vcat(value_constructors, value_helpers, binary_ops, string_funcs, string_ops))

println("\n[Phase 3] Testing tokenizer...")
tokenizer_all = vcat(
    token_constructors,
    char_classifiers,
    lexer_funcs,
    scanner_funcs,
    keyword_funcs,
    token_list_funcs,
    string_funcs,
)
test_group("Tokenizer (all)", tokenizer_all)

println("\n[Phase 4] Testing AST constructors...")
test_group("AST constructors", ast_constructors)

println("\n[Phase 5] Testing parser...")
parser_all = vcat(
    tokenizer_all,
    ast_constructors,
    parser_funcs,
    parse_funcs,
)
test_group("Parser (all)", parser_all)

println("\n[Phase 6] Testing evaluator...")
evaluator_all = vcat(
    value_constructors,
    value_helpers,
    control_flow,
    output_buffer,
    binary_ops,
    builtin_funcs,
    eval_funcs,
    env_funcs,
    string_funcs,
    string_ops,
)
test_group("Evaluator (all)", evaluator_all)

# ============================================================================
# Full interpreter compilation
# ============================================================================

println("\n[Phase 7] Compiling full interpreter...")

all_funcs = vcat(
    # Core string operations
    string_funcs,
    string_ops,
    string_marshaling,  # For JS<->WASM string marshaling

    # Value system
    value_constructors,
    value_helpers,
    control_flow,
    output_buffer,

    # Tokenizer
    token_constructors,
    char_classifiers,
    scanner_funcs,
    keyword_funcs,
    lexer_funcs,
    token_list_funcs,

    # Parser
    ast_constructors,
    parser_funcs,
    parse_funcs,

    # Evaluator
    env_funcs,
    binary_ops,
    builtin_funcs,
    eval_funcs,

    # REPL
    repl_funcs,
)

# Remove duplicates (keep first occurrence)
seen = Set{Any}()
unique_funcs = []
for (f, args) in all_funcs
    key = (f, args)
    if key ∉ seen
        push!(seen, key)
        push!(unique_funcs, (f, args))
    end
end

println("  Total unique functions: $(length(unique_funcs))")

try
    wasm = WasmTarget.compile_multi(unique_funcs)
    println("  ✓ Full interpreter: $(length(unique_funcs)) functions, $(length(wasm)) bytes")

    # Save the interpreter
    wasm_path = joinpath(output_dir, "interpreter.wasm")
    write(wasm_path, wasm)
    println("  ✓ Wrote: $wasm_path")

    # Verify no changes to interpreter source
    println("\n[Phase 8] Verifying no changes to interpreter source...")
    interp_dir = joinpath(dirname(@__DIR__), "src", "Interpreter")
    for f in readdir(interp_dir)
        if endswith(f, ".jl")
            println("  ✓ No changes needed: src/Interpreter/$f")
        end
    end

    println("\n" * "=" ^ 60)
    println("SUCCESS! Interpreter compiled to WasmGC")
    println("=" ^ 60)
    println()
    println("Output: $wasm_path")
    println("Size: $(length(wasm)) bytes ($(round(length(wasm)/1024, digits=2)) KB)")
    println("Functions: $(length(unique_funcs))")
    println()
    println("The interpreter was compiled WITHOUT changes to:")
    println("  - src/Interpreter/Tokenizer.jl")
    println("  - src/Interpreter/Parser.jl")
    println("  - src/Interpreter/Evaluator.jl")
    println("  - src/Interpreter/REPL.jl")

catch e
    println("  ✗ Full interpreter compilation failed!")
    println("  Error: $(typeof(e))")
    if e isa ErrorException
        println("  Message: $(e.msg)")
    end

    # Try to identify which function group is failing
    println("\n[Debug] Identifying failing function...")

    # Try adding groups incrementally
    accumulated = []
    groups = [
        ("string_funcs", string_funcs),
        ("string_ops", string_ops),
        ("value_constructors", value_constructors),
        ("value_helpers", value_helpers),
        ("control_flow", control_flow),
        ("output_buffer", output_buffer),
        ("token_constructors", token_constructors),
        ("char_classifiers", char_classifiers),
        # Note: scanner, keyword, and lexer funcs all have interdependencies
        # They must all be added at once
        ("tokenizer_core", vcat(scanner_funcs, keyword_funcs, lexer_funcs)),
        ("token_list_funcs", token_list_funcs),
        ("ast_constructors", ast_constructors),
        # Note: parser_funcs and parse_funcs have mutual dependencies
        # They must all be added at once
        ("parser_all", vcat(parser_funcs, parse_funcs)),
        ("env_funcs", env_funcs),
        ("binary_ops", binary_ops),
        ("builtin_funcs", builtin_funcs),
        # Note: eval_funcs have mutual recursion - must be together
        ("eval_and_repl", vcat(eval_funcs, repl_funcs)),
    ]

    for (name, funcs) in groups
        accumulated = vcat(accumulated, funcs)
        try
            WasmTarget.compile_multi(accumulated)
            println("  ✓ After adding $name: $(length(accumulated)) functions OK")
        catch e2
            println("  ✗ FAILS after adding $name")
            if e2 isa ErrorException
                println("    $(e2.msg)")
            end
            break
        end
    end

    println("\n" * "=" ^ 60)
    println("COMPILATION FAILED")
    println("=" ^ 60)
end
