using Pkg
Pkg.activate(dirname(@__DIR__))
using WasmTarget

# Test parse_primary with all required dependencies
funcs = [
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
    # control_flow
    (WasmTarget.cf_normal, ()),
    (WasmTarget.cf_return, (WasmTarget.Value,)),
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
    # parser_funcs
    (WasmTarget.parser_new, (String, Int32)),
    (WasmTarget.parser_current, (WasmTarget.Parser,)),
    (WasmTarget.parser_current_type, (WasmTarget.Parser,)),
    (WasmTarget.parser_check, (WasmTarget.Parser, Int32)),
    (getfield(WasmTarget, Symbol("parser_advance!")), (WasmTarget.Parser,)),
    (getfield(WasmTarget, Symbol("parser_consume!")), (WasmTarget.Parser, Int32)),
    (getfield(WasmTarget, Symbol("parser_skip_terminators!")), (WasmTarget.Parser,)),
    (WasmTarget.parser_at_end, (WasmTarget.Parser,)),
    # parse_primary
    (WasmTarget.parse_primary, (WasmTarget.Parser,)),
]

println("Compiling $(length(funcs)) functions...")
try
    wasm = WasmTarget.compile_multi(funcs)
    println("OK: $(length(wasm)) bytes")
catch e
    println("ERR: $(e isa ErrorException ? e.msg : sprint(showerror, e))")
end
