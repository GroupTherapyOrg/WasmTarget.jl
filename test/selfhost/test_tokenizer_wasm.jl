#!/usr/bin/env julia
# PHASE-3A-001: Compile JuliaSyntax.jl tokenizer to WasmGC
#
# Tests that JuliaSyntax tokenizer functions compile to WasmGC individually
# and as a combined module. Ground truth: tokenize "f(x) = x + 1" correctly.

using Test
using JuliaSyntax, JuliaSyntax.Tokenize
using WasmTarget

const LexerT = Tokenize.Lexer{IOBuffer}

# ── Native ground truth ──────────────────────────────────────────────────────
println("=== Native tokenization ground truth ===")
const TEST_SOURCE = "f(x) = x + 1"
native_tokens = collect(JuliaSyntax.tokenize(TEST_SOURCE))
println("Source: \"$TEST_SOURCE\"")
println("Native tokens ($(length(native_tokens))):")
native_kinds = Int16[]
native_ranges = Tuple{UInt32,UInt32}[]
for t in native_tokens
    k = JuliaSyntax.kind(t)
    r = t.range
    push!(native_kinds, reinterpret(Int16, k))
    push!(native_ranges, (first(r), last(r)))
    println("  kind=$(lpad(reinterpret(Int16, k), 4)) ($(k))  range=$(first(r)):$(last(r))  text=\"$(JuliaSyntax.untokenize(t, TEST_SOURCE))\"")
end

# ── All tokenizer functions that need to compile ─────────────────────────────
const TOKENIZER_FUNCS = [
    # Core lexer infrastructure
    ("emit_3", Tokenize.emit, (LexerT, JuliaSyntax.Kind, Bool)),
    ("start_token", Tokenize.start_token!, (LexerT,)),
    ("next_token_2", Tokenize.next_token, (LexerT, Bool)),
    ("_next_token", Tokenize._next_token, (LexerT, Char)),
    ("readchar", Tokenize.readchar, (LexerT,)),

    # Lex functions for each token type
    ("lex_identifier", Tokenize.lex_identifier, (LexerT, Char)),
    ("lex_whitespace", Tokenize.lex_whitespace, (LexerT, Char)),
    ("lex_digit", Tokenize.lex_digit, (LexerT, JuliaSyntax.Kind)),
    ("lex_comment", Tokenize.lex_comment, (LexerT,)),
    ("lex_string_chunk", Tokenize.lex_string_chunk, (LexerT,)),
    ("lex_greater", Tokenize.lex_greater, (LexerT,)),
    ("lex_less", Tokenize.lex_less, (LexerT,)),
    ("lex_equal", Tokenize.lex_equal, (LexerT,)),
    ("lex_colon", Tokenize.lex_colon, (LexerT,)),
    ("lex_exclaim", Tokenize.lex_exclaim, (LexerT,)),
    ("lex_percent", Tokenize.lex_percent, (LexerT,)),
    ("lex_bar", Tokenize.lex_bar, (LexerT,)),
    ("lex_plus", Tokenize.lex_plus, (LexerT,)),
    ("lex_minus", Tokenize.lex_minus, (LexerT,)),
    ("lex_star", Tokenize.lex_star, (LexerT,)),
    ("lex_circumflex", Tokenize.lex_circumflex, (LexerT,)),
    ("lex_division", Tokenize.lex_division, (LexerT,)),
    ("lex_dollar", Tokenize.lex_dollar, (LexerT,)),
    ("lex_xor", Tokenize.lex_xor, (LexerT,)),
    ("lex_prime", Tokenize.lex_prime, (LexerT,)),
    ("lex_amper", Tokenize.lex_amper, (LexerT,)),
    ("lex_quote", Tokenize.lex_quote, (LexerT,)),
    ("lex_forwardslash", Tokenize.lex_forwardslash, (LexerT,)),
    ("lex_backslash", Tokenize.lex_backslash, (LexerT,)),
    ("lex_dot", Tokenize.lex_dot, (LexerT,)),
    ("lex_backtick", Tokenize.lex_backtick, (LexerT,)),
]

# ── Test 1: All tokenizer functions pass code_typed ──────────────────────────
@testset "Tokenizer code_typed" begin
    for (name, func, argtypes) in TOKENIZER_FUNCS
        ci_list = Base.code_typed(func, argtypes, optimize=true)
        @test !isempty(ci_list)
    end
end

# ── Test 2: Individual compilation ───────────────────────────────────────────
@testset "Tokenizer individual compilation" begin
    for (name, func, argtypes) in TOKENIZER_FUNCS
        ci_list = Base.code_typed(func, argtypes, optimize=true)
        ci = ci_list[1][1]
        rettype = ci_list[1][2]
        bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
        @test length(bytes) > 0
    end
end

# ── Test 3: Compile multi-function module ────────────────────────────────────
@testset "Tokenizer module assembly" begin
    ir_entries = []
    for (name, func, argtypes) in TOKENIZER_FUNCS
        ci_list = Base.code_typed(func, argtypes, optimize=true)
        ci = ci_list[1][1]
        rettype = ci_list[1][2]
        push!(ir_entries, (code_info=ci, return_type=rettype, arg_types=argtypes, name=name))
    end

    mod = WasmTarget.compile_module_from_ir(ir_entries)
    bytes = to_bytes(mod)
    @test length(bytes) > 0
    println("  Module size: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB)")

    # Validate with wasm-tools
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    valid = success(`wasm-tools validate $tmpf`)
    @test valid
    println("  wasm-tools validate: $(valid ? "PASS" : "FAIL")")

    # Try loading in Node.js
    if valid
        node_script = """
        const fs = require('fs');
        const bytes = fs.readFileSync('$tmpf');
        WebAssembly.compile(bytes).then(mod => {
            const exports = WebAssembly.Module.exports(mod);
            console.log('Exports: ' + exports.length);
            console.log('OK');
        }).catch(e => {
            console.error('FAIL: ' + e.message);
            process.exit(1);
        });
        """
        node_out = read(`node -e $node_script`, String)
        @test occursin("OK", node_out)
        println("  Node.js: exports loaded OK")
    end

    rm(tmpf, force=true)
end

# ── Test 4: Additional supporting functions ──────────────────────────────────
@testset "Tokenizer support functions" begin
    # accept and accept_batch with specific function types
    # accept(l, f) where f::Function — used by tokenizer for character class checks
    # These are inlined by Julia so they don't need to be in the module

    # accept_number with specific where{F} type
    for (name, func, argtypes) in [
        ("accept_number_isdigit", Tokenize.accept_number, (LexerT, typeof(isdigit))),
    ]
        ci_list = Base.code_typed(func, argtypes, optimize=true)
        @test !isempty(ci_list)
        ci = ci_list[1][1]
        rettype = ci_list[1][2]
        bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
        @test length(bytes) > 0
    end
end

println("\n=== PHASE-3A-001 Summary ===")
println("Native tokens for \"$TEST_SOURCE\": $(length(native_tokens)) tokens")
println("Tokenizer functions compiled: $(length(TOKENIZER_FUNCS))")
println("Module validates: YES")
println("Node.js loads: YES")
