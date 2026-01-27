using Pkg
Pkg.activate(dirname(@__DIR__))
using WasmTarget

# All functions accumulated before parser_all
base = [
    # string_funcs
    (WasmTarget.digit_to_str, (Int32,)),
    (WasmTarget.int_to_string, (Int32,)),
    # string_ops
    (WasmTarget.str_eq, (String, String)),
    (WasmTarget.str_len, (String,)),
    (WasmTarget.str_char, (String, Int32)),
    # value_constructors
    (WasmTarget.val_nothing, ()),
    (WasmTarget.val_int, (Int32,)),
    (WasmTarget.val_float, (Float32,)),
    (WasmTarget.val_bool, (Int32,)),
    (WasmTarget.val_string, (String,)),
    (WasmTarget.val_func, (WasmTarget.ASTNode,)),
    (WasmTarget.val_error, ()),
    # value_helpers
    (WasmTarget.val_is_truthy, (WasmTarget.Value,)),
    (WasmTarget.value_to_float, (WasmTarget.Value,)),
    (WasmTarget.value_to_string, (WasmTarget.Value,)),
    (WasmTarget.float_to_string, (Float32,)),
    # control_flow
    (WasmTarget.cf_normal, ()),
    (WasmTarget.cf_return, (WasmTarget.Value,)),
    # output_buffer
    (WasmTarget.output_buffer_get, ()),
    (getfield(WasmTarget, Symbol("output_buffer_set!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_append!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_clear!")), ()),
    # token_constructors
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_error, (Int32,)),
    (WasmTarget.token_simple, (Int32, Int32, Int32)),
    (WasmTarget.token_int, (Int32, Int32, Int32)),
    (WasmTarget.token_float, (Float32, Int32, Int32)),
    # char_classifiers
    (WasmTarget.is_digit, (Int32,)),
    (WasmTarget.is_alpha, (Int32,)),
    (WasmTarget.is_alnum, (Int32,)),
    (WasmTarget.is_whitespace, (Int32,)),
    (WasmTarget.is_newline, (Int32,)),
    # tokenizer_core
    (WasmTarget.scan_integer, (WasmTarget.Lexer,)),
    (WasmTarget.scan_float_after_dot, (WasmTarget.Lexer, Int32, Int32)),
    (WasmTarget.scan_identifier, (WasmTarget.Lexer,)),
    (WasmTarget.scan_string, (WasmTarget.Lexer,)),
    (WasmTarget.scan_operator, (WasmTarget.Lexer,)),
    (WasmTarget.check_keyword, (String, Int32, Int32)),
    (WasmTarget.check_keyword_2, (String, Int32)),
    (WasmTarget.check_keyword_3, (String, Int32)),
    (WasmTarget.check_keyword_4, (String, Int32)),
    (WasmTarget.check_keyword_5, (String, Int32)),
    (WasmTarget.check_keyword_6, (String, Int32)),
    (WasmTarget.check_keyword_7, (String, Int32)),
    (WasmTarget.check_keyword_8, (String, Int32)),
    (WasmTarget.lexer_new, (String,)),
    (WasmTarget.lexer_peek, (WasmTarget.Lexer,)),
    (WasmTarget.lexer_peek_at, (WasmTarget.Lexer, Int32)),
    (getfield(WasmTarget, Symbol("lexer_advance!")), (WasmTarget.Lexer,)),
    (getfield(WasmTarget, Symbol("lexer_skip_whitespace!")), (WasmTarget.Lexer,)),
    (getfield(WasmTarget, Symbol("lexer_skip_comment!")), (WasmTarget.Lexer,)),
    (getfield(WasmTarget, Symbol("lexer_next_token!")), (WasmTarget.Lexer,)),
    # token_list_funcs
    (WasmTarget.token_list_new, (Int32,)),
    (getfield(WasmTarget, Symbol("token_list_push!")), (WasmTarget.TokenList, WasmTarget.Token)),
    (WasmTarget.token_list_get, (WasmTarget.TokenList, Int32)),
    (WasmTarget.tokenize, (String, Int32)),
    # ast_constructors
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

# parser_funcs
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

# parse_funcs
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

all_funcs = vcat(base, parser_funcs, parse_funcs)
println("Compiling $(length(all_funcs)) functions...")

try
    wasm = WasmTarget.compile_multi(all_funcs)
    println("OK: $(length(wasm)) bytes")
catch e
    println("ERR: $(e isa ErrorException ? e.msg : sprint(showerror, e))")
end
