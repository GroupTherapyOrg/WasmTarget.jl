#!/usr/bin/env julia
# Test compile_multi incrementally

using WasmTarget

# Helper
getfn(sym::Symbol) = getfield(WasmTarget, sym)
Lexer = WasmTarget.Lexer
Token = WasmTarget.Token
TokenList = WasmTarget.TokenList

all_funcs = [
    # 1-5: Character classifiers
    (WasmTarget.is_digit, (Int32,)),
    (WasmTarget.is_alpha, (Int32,)),
    (WasmTarget.is_alnum, (Int32,)),
    (WasmTarget.is_whitespace, (Int32,)),
    (WasmTarget.is_newline, (Int32,)),
    # 6-10: Token constructors
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_error, (Int32,)),
    (WasmTarget.token_simple, (Int32, Int32, Int32)),
    (WasmTarget.token_int, (Int32, Int32, Int32)),
    (WasmTarget.token_float, (Float32, Int32, Int32)),
    # 11-16: Lexer methods
    (WasmTarget.lexer_new, (String,)),
    (WasmTarget.lexer_peek, (Lexer,)),
    (WasmTarget.lexer_peek_at, (Lexer, Int32)),
    (getfn(Symbol("lexer_advance!")), (Lexer,)),
    (getfn(Symbol("lexer_skip_whitespace!")), (Lexer,)),
    (getfn(Symbol("lexer_skip_comment!")), (Lexer,)),
    # 17-25: Keywords (need to come before scanners that call them)
    (WasmTarget.check_keyword_2, (String, Int32)),
    (WasmTarget.check_keyword_3, (String, Int32)),
    (WasmTarget.check_keyword_4, (String, Int32)),
    (WasmTarget.check_keyword_5, (String, Int32)),
    (WasmTarget.check_keyword_6, (String, Int32)),
    (WasmTarget.check_keyword_7, (String, Int32)),
    (WasmTarget.check_keyword_8, (String, Int32)),
    (WasmTarget.check_keyword, (String, Int32, Int32)),
    # 26-30: Scanners (scan_float_after_dot first since scan_integer calls it)
    (WasmTarget.scan_float_after_dot, (Lexer, Int32, Int32)),
    (WasmTarget.scan_integer, (Lexer,)),
    (WasmTarget.scan_identifier, (Lexer,)),
    (WasmTarget.scan_string, (Lexer,)),
    (WasmTarget.scan_operator, (Lexer,)),
    # 31-33: Token list
    (WasmTarget.token_list_new, (Int32,)),
    (getfn(Symbol("token_list_push!")), (TokenList, Token)),
    (WasmTarget.token_list_get, (TokenList, Int32)),
    # 34-35: Main tokenize
    (getfn(Symbol("lexer_next_token!")), (Lexer,)),
    (WasmTarget.tokenize, (String, Int32)),
]

# Test incrementally larger sets
for n in [5, 10, 15, 16, 17, 18, 19, 20, 21, 25, 30, 35]
    if n > length(all_funcs)
        break
    end
    funcs = all_funcs[1:n]
    fname = nameof(funcs[end][1])
    try
        bytes = compile_multi(funcs)
        println("n=$n ($fname): OK ($(length(bytes)) bytes)")
    catch e
        println("n=$n ($fname): FAILED")
        println("  Error: ", e)
        break
    end
end
