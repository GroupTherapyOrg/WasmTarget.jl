#!/usr/bin/env julia
# PHASE-3A-002: Compile JuliaSyntax.jl parser core (parseall) to WasmGC
#
# Tests that JuliaSyntax parser functions compile to WasmGC individually
# and as a combined module. The parser uses ParseState (wraps ParseStream).
# Key functions: parse_stmts, parse_atom, parse_call, parse_unary, etc.

using Test
using JuliaSyntax
using WasmTarget

const PSt = JuliaSyntax.ParseState
const PS = JuliaSyntax.ParseStream

# ── Native ground truth ──────────────────────────────────────────────────────
println("=== Native parse ground truth ===")
const TEST_EXPRS = [
    "f(x) = x + 1",
    "x + y * z",
    "if x > 0; x; else; -x; end",
    "for i in 1:10; end",
    "struct Point; x::Float64; end",
    "a = 1 + 2",
    "f(x, y) = x * y",
    "x > 0 ? x : -x",
    "while x > 0; x -= 1; end",
    "begin; a = 1; b = 2; end",
]

for expr in TEST_EXPRS
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, expr)
    println("  \"$expr\" → $(JuliaSyntax.kind(tree)) children=$(length(JuliaSyntax.children(tree)))")
end

# ── All parser functions to compile (ParseState-based) ───────────────────────
# Organized by complexity: small first, then large
const PARSER_FUNCS = [
    # ── Infrastructure: bump, peek, emit (ParseStream) ──
    ("bump_invisible_1", JuliaSyntax.bump_invisible, (PS,)),
    ("emit_3", JuliaSyntax.emit, (PS, JuliaSyntax.Kind, Int)),
    ("emit_diagnostic_1", JuliaSyntax.emit_diagnostic, (PS, Int, Int, JuliaSyntax.Kind)),
    ("peek_behind_1", JuliaSyntax.peek_behind, (PS,)),

    # ── Thin wrappers (2 stmts) ──
    ("parse_expr", JuliaSyntax.parse_expr, (PSt,)),
    ("parse_or", JuliaSyntax.parse_or, (PSt,)),
    ("parse_and", JuliaSyntax.parse_and, (PSt,)),
    ("parse_pipe_lt", JuliaSyntax.parse_pipe_lt, (PSt,)),
    ("parse_pipe_gt", JuliaSyntax.parse_pipe_gt, (PSt,)),
    ("parse_shift", JuliaSyntax.parse_shift, (PSt,)),
    ("parse_term", JuliaSyntax.parse_term, (PSt,)),
    ("parse_rational", JuliaSyntax.parse_rational, (PSt,)),
    ("parse_pair", JuliaSyntax.parse_pair, (PSt,)),
    ("parse_factor_after", JuliaSyntax.parse_factor_after, (PSt,)),
    ("parse_call_arglist", JuliaSyntax.parse_call_arglist, (PSt,)),
    ("parse_comprehension", JuliaSyntax.parse_comprehension, (PSt,)),
    ("parse_vect", JuliaSyntax.parse_vect, (PSt,)),

    # ── Small functions (< 100 stmts) ──
    ("parse_eq", JuliaSyntax.parse_eq, (PSt,)),
    ("parse_assignment", JuliaSyntax.parse_assignment, (PSt,)),
    ("parse_call", JuliaSyntax.parse_call, (PSt,)),
    ("parse_factor", JuliaSyntax.parse_factor, (PSt,)),
    ("parse_array", JuliaSyntax.parse_array, (PSt,)),

    # ── Medium functions (100-500 stmts) ──
    ("parse_block_1", JuliaSyntax.parse_block, (PSt,)),
    ("parse_iteration_specs", JuliaSyntax.parse_iteration_specs, (PSt,)),
    ("parse_where", JuliaSyntax.parse_where, (PSt,)),
    ("parse_space_separated", JuliaSyntax.parse_space_separated_exprs, (PSt,)),
    ("parse_factor_with_init", JuliaSyntax.parse_factor_with_initial_ex, (PSt,)),
    ("parse_RtoL", JuliaSyntax.parse_RtoL, (PSt,)),
    ("parse_comma_separated", JuliaSyntax.parse_comma_separated, (PSt,)),
    ("parse_lazy_cond", JuliaSyntax.parse_lazy_cond, (PSt,)),
    ("parse_macro_name", JuliaSyntax.parse_macro_name, (PSt,)),
    ("parse_public", JuliaSyntax.parse_public, (PSt,)),
    ("parse_with_chains", JuliaSyntax.parse_with_chains, (PSt,)),
    ("parse_eq_star", JuliaSyntax.parse_eq_star, (PSt,)),
    ("parse_invalid_ops", JuliaSyntax.parse_invalid_ops, (PSt,)),
    ("parse_struct_field", JuliaSyntax.parse_struct_field, (PSt,)),

    # ── Large functions (500-1000 stmts) ──
    ("parse_chain", JuliaSyntax.parse_chain, (PSt,)),
    ("parse_toplevel", JuliaSyntax.parse_toplevel, (PSt,)),
    ("parse_docstring_1", JuliaSyntax.parse_docstring, (PSt,)),
    ("parse_stmts", JuliaSyntax.parse_stmts, (PSt,)),
    ("parse_arrow", JuliaSyntax.parse_arrow, (PSt,)),
    ("parse_comma_1", JuliaSyntax.parse_comma, (PSt,)),
    ("parse_LtoR", JuliaSyntax.parse_LtoR, (PSt,)),
    ("parse_cat", JuliaSyntax.parse_cat, (PSt,)),
    ("parse_import", JuliaSyntax.parse_import, (PSt,)),
    ("parse_Nary", JuliaSyntax.parse_Nary, (PSt,)),
    ("parse_iteration_spec", JuliaSyntax.parse_iteration_spec, (PSt,)),
    ("parse_do", JuliaSyntax.parse_do, (PSt,)),
    ("parse_catch", JuliaSyntax.parse_catch, (PSt,)),
    ("parse_where_chain", JuliaSyntax.parse_where_chain, (PSt,)),
    ("parse_juxtapose", JuliaSyntax.parse_juxtapose, (PSt,)),
    ("parse_decl_with_init", JuliaSyntax.parse_decl_with_initial_ex, (PSt,)),

    # ── Very large functions (1000+ stmts) ──
    ("parse_unary_subtype", JuliaSyntax.parse_unary_subtype, (PSt,)),
    ("parse_unary_prefix_1", JuliaSyntax.parse_unary_prefix, (PSt,)),
    ("parse_generator", JuliaSyntax.parse_generator, (PSt,)),
    ("parse_brackets_1", JuliaSyntax.parse_brackets, (PSt,)),
    ("parse_paren_1", JuliaSyntax.parse_paren, (PSt,)),
    ("parse_comparison_1", JuliaSyntax.parse_comparison, (PSt, Bool)),
    ("parse_imports", JuliaSyntax.parse_imports, (PSt,)),
    ("parse_import_path", JuliaSyntax.parse_import_path, (PSt,)),
    ("parse_import_atsym_1", JuliaSyntax.parse_import_atsym, (PSt,)),
    ("parse_cond", JuliaSyntax.parse_cond, (PSt,)),
    ("parse_func_sig", JuliaSyntax.parse_function_signature, (PSt,)),

    # ── Huge functions (3000+ stmts) — these may have control flow issues ──
    ("parse_unary", JuliaSyntax.parse_unary, (PSt,)),
    ("parse_range", JuliaSyntax.parse_range, (PSt,)),
    ("parse_string", JuliaSyntax.parse_string, (PSt,)),
    ("parse_call_chain_1", JuliaSyntax.parse_call_chain, (PSt, Bool)),
    ("parse_resword", JuliaSyntax.parse_resword, (PSt,)),
    ("parse_atom_1", JuliaSyntax.parse_atom, (PSt,)),
]

# Additional ParseStream infrastructure functions
const STREAM_FUNCS = [
    ("bump_ps_1", JuliaSyntax.bump, (PS,)),
    ("bump_trivia_1", JuliaSyntax.bump_trivia, (PS,)),
    ("peek_token_1", JuliaSyntax.peek_token, (PS,)),
]

# ── Test 1: All parser functions pass code_typed ──────────────────────────────
@testset "Parser code_typed" begin
    for (name, func, argtypes) in PARSER_FUNCS
        ci_list = Base.code_typed(func, argtypes, optimize=true)
        @test !isempty(ci_list) "code_typed failed for $name"
    end
    for (name, func, argtypes) in STREAM_FUNCS
        ci_list = Base.code_typed(func, argtypes, optimize=true)
        @test !isempty(ci_list) "code_typed failed for $name"
    end
end

# ── Test 2: Individual compilation ───────────────────────────────────────────
compiled_count = 0
failed_names = String[]
@testset "Parser individual compilation" begin
    for (name, func, argtypes) in vcat(STREAM_FUNCS, PARSER_FUNCS)
        ci_list = Base.code_typed(func, argtypes, optimize=true)
        if isempty(ci_list)
            push!(failed_names, "$name: empty code_typed")
            @test false "empty code_typed for $name"
            continue
        end
        ci = ci_list[1][1]
        rettype = ci_list[1][2]
        try
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            @test length(bytes) > 0
            global compiled_count += 1
        catch e
            push!(failed_names, "$name: $(sprint(showerror, e))")
            @test false "$name failed to compile: $(sprint(showerror, e))"
        end
    end
end
println("  Compiled: $compiled_count / $(length(PARSER_FUNCS) + length(STREAM_FUNCS))")
if !isempty(failed_names)
    println("  Failed:")
    for f in failed_names
        println("    $f")
    end
end

# ── Test 3: Parser module assembly ───────────────────────────────────────────
@testset "Parser module assembly" begin
    ir_entries = []
    skipped = String[]
    for (name, func, argtypes) in vcat(STREAM_FUNCS, PARSER_FUNCS)
        try
            ci_list = Base.code_typed(func, argtypes, optimize=true)
            if isempty(ci_list)
                push!(skipped, name)
                continue
            end
            ci = ci_list[1][1]
            rettype = ci_list[1][2]
            # Test individual compilation first
            WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            push!(ir_entries, (ci, rettype, argtypes, name, func))
        catch e
            push!(skipped, "$name: $(sprint(showerror, e))")
        end
    end

    println("  Functions in module: $(length(ir_entries))")
    if !isempty(skipped)
        println("  Skipped: $(length(skipped))")
        for s in skipped
            println("    $s")
        end
    end

    if length(ir_entries) > 0
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
            println("  Node.js: $(strip(node_out))")
        end

        # Save module for later use
        parser_wasm = joinpath(@__DIR__, "parser_module.wasm")
        write(parser_wasm, bytes)
        println("  Saved to: parser_module.wasm")

        rm(tmpf, force=true)
    end
end

println("\n=== PHASE-3A-002 Summary ===")
println("Parser functions: $(length(PARSER_FUNCS)) ParseState + $(length(STREAM_FUNCS)) ParseStream")
println("Compiled: $compiled_count individually")
println("Test expressions: $(length(TEST_EXPRS))")
println("Note: Full parseall execution requires tokenizer + parser + ParseStream constructor")
println("  integration. Large branchy functions (3000+ stmts) may have control flow")
println("  correctness issues — same class as tokenizer char classification / stackifier sin().")
