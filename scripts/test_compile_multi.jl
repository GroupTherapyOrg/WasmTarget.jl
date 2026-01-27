#!/usr/bin/env julia
# Test compile_multi with increasing numbers of interpreter functions

using WasmTarget

# Import the types
const Lexer = WasmTarget.Lexer
const Token = WasmTarget.Token
const TokenList = WasmTarget.TokenList

# Helper to get function from module with special chars
getfn(sym::Symbol) = getfield(WasmTarget, sym)

# Build list of tokenizer functions
tokenizer_funcs = [
    # Character classifiers
    (WasmTarget.is_digit, (Int32,)),
    (WasmTarget.is_alpha, (Int32,)),
    (WasmTarget.is_alnum, (Int32,)),
    (WasmTarget.is_whitespace, (Int32,)),
    (WasmTarget.is_newline, (Int32,)),

    # Token constructors
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_error, (Int32,)),
    (WasmTarget.token_simple, (Int32, Int32, Int32)),
    (WasmTarget.token_int, (Int32, Int32, Int32)),
    (WasmTarget.token_float, (Float32, Int32, Int32)),

    # Lexer methods
    (WasmTarget.lexer_new, (String,)),
    (WasmTarget.lexer_peek, (Lexer,)),
    (WasmTarget.lexer_peek_at, (Lexer, Int32)),
    (getfn(Symbol("lexer_advance!")), (Lexer,)),
    (getfn(Symbol("lexer_skip_whitespace!")), (Lexer,)),
    (getfn(Symbol("lexer_skip_comment!")), (Lexer,)),

    # Scanners
    (WasmTarget.scan_integer, (Lexer,)),
    (WasmTarget.scan_float_after_dot, (Lexer, Int32, Int32)),
    (WasmTarget.scan_identifier, (Lexer,)),
    (WasmTarget.scan_string, (Lexer,)),
    (WasmTarget.scan_operator, (Lexer,)),

    # Keyword detection
    (WasmTarget.check_keyword, (String, Int32, Int32)),
    (WasmTarget.check_keyword_2, (String, Int32)),
    (WasmTarget.check_keyword_3, (String, Int32)),
    (WasmTarget.check_keyword_4, (String, Int32)),
    (WasmTarget.check_keyword_5, (String, Int32)),
    (WasmTarget.check_keyword_6, (String, Int32)),
    (WasmTarget.check_keyword_7, (String, Int32)),
    (WasmTarget.check_keyword_8, (String, Int32)),

    # Token list
    (WasmTarget.token_list_new, (Int32,)),
    (getfn(Symbol("token_list_push!")), (TokenList, Token)),
    (WasmTarget.token_list_get, (TokenList, Int32)),

    # Main tokenize
    (getfn(Symbol("lexer_next_token!")), (Lexer,)),
    (WasmTarget.tokenize, (String, Int32)),
]

# Test one function at a time to find the problematic one
println("Testing functions individually...")
for (i, (fn, sig)) in enumerate(tokenizer_funcs)
    try
        # Use compile_multi with single function
        bytes = compile_multi([(fn, sig)])
        println("[$i] $(nameof(fn)) - OK ($(length(bytes)) bytes)")
    catch e
        println("[$i] $(nameof(fn)) - FAILED: ", e)
        break  # Stop at first failure
    end
end
