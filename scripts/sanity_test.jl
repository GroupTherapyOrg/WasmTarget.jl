#!/usr/bin/env julia
using WasmTarget

println("Quick sanity tests...")

# Test 1: Basic function compilation still works
f1(x::Int64) = x + 1
bytes = compile(f1, (Int64,))
println("1. Basic compile: OK ($(length(bytes)) bytes)")

# Test 2: Struct field access
mutable struct Point
    x::Int32
    y::Int32
end
get_x(p::Point)::Int32 = p.x
set_x!(p::Point, val::Int32)::Nothing = begin p.x = val; nothing end

bytes = compile_multi([
    (get_x, (Point,)),
    (set_x!, (Point, Int32)),
])
println("2. Struct field access: OK ($(length(bytes)) bytes)")

# Test 3: 25 interpreter functions
Lexer = WasmTarget.Lexer
getfn(sym::Symbol) = getfield(WasmTarget, sym)

funcs_25 = [
    (WasmTarget.is_digit, (Int32,)),
    (WasmTarget.is_alpha, (Int32,)),
    (WasmTarget.is_alnum, (Int32,)),
    (WasmTarget.is_whitespace, (Int32,)),
    (WasmTarget.is_newline, (Int32,)),
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_error, (Int32,)),
    (WasmTarget.token_simple, (Int32, Int32, Int32)),
    (WasmTarget.token_int, (Int32, Int32, Int32)),
    (WasmTarget.token_float, (Float32, Int32, Int32)),
    (WasmTarget.lexer_new, (String,)),
    (WasmTarget.lexer_peek, (Lexer,)),
    (WasmTarget.lexer_peek_at, (Lexer, Int32)),
    (getfn(Symbol("lexer_advance!")), (Lexer,)),
    (getfn(Symbol("lexer_skip_whitespace!")), (Lexer,)),
    (getfn(Symbol("lexer_skip_comment!")), (Lexer,)),
    (WasmTarget.check_keyword_2, (String, Int32)),
    (WasmTarget.check_keyword_3, (String, Int32)),
    (WasmTarget.check_keyword_4, (String, Int32)),
    (WasmTarget.check_keyword_5, (String, Int32)),
    (WasmTarget.check_keyword_6, (String, Int32)),
    (WasmTarget.check_keyword_7, (String, Int32)),
    (WasmTarget.check_keyword_8, (String, Int32)),
    (WasmTarget.check_keyword, (String, Int32, Int32)),
    (WasmTarget.scan_float_after_dot, (Lexer, Int32, Int32)),
]

bytes = compile_multi(funcs_25)
println("3. 25 interpreter functions: OK ($(length(bytes)) bytes)")

println()
println("All sanity tests passed!")
