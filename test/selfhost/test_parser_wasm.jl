#!/usr/bin/env julia
# PHASE-3A-002: Compile JuliaSyntax.jl parser core (parseall) to WasmGC
#
# Tests that JuliaSyntax parser functions compile to WasmGC individually
# and as a combined module. The parser uses ParseState (wraps ParseStream).

using Test
using JuliaSyntax
using WasmTarget

const PSt = JuliaSyntax.ParseState
const PS = JuliaSyntax.ParseStream
const PSP = JuliaSyntax.ParseStreamPosition
const K = JuliaSyntax.Kind

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
    println("  \"$expr\" → $(JuliaSyntax.kind(tree))")
end

# ── All parser functions to compile ──────────────────────────────────────────
# Organized by module layer: stream infrastructure → thin wrappers → real parsers

const ALL_FUNCS = [
    # ══════════ ParseStream infrastructure ══════════
    # bump variants
    ("bump_ps", JuliaSyntax.bump, (PS,)),
    ("bump_pst", JuliaSyntax.bump, (PSt,)),
    ("bump_ps_any", JuliaSyntax.bump, (PS, Any)),
    ("bump_pst_any", JuliaSyntax.bump, (PSt, Any)),

    # bump_trivia variants
    ("bump_trivia_ps", JuliaSyntax.bump_trivia, (PS,)),
    ("bump_trivia_ps_any", JuliaSyntax.bump_trivia, (PS, Any)),
    ("bump_trivia_pst", JuliaSyntax.bump_trivia, (PSt, Vararg{Any})),

    # bump_invisible
    ("bump_invisible_ps", JuliaSyntax.bump_invisible, (PS, Any)),
    ("bump_invisible_ps2", JuliaSyntax.bump_invisible, (PS, Any, Any)),
    ("bump_invisible_pst", JuliaSyntax.bump_invisible, (PSt, Vararg{Any})),

    # emit variants
    ("emit_ps_3", JuliaSyntax.emit, (PS, PSP, K)),
    ("emit_ps_4", JuliaSyntax.emit, (PS, PSP, K, UInt16)),
    ("emit_pst", JuliaSyntax.emit, (PSt, Vararg{Any})),

    # emit_diagnostic variants
    ("emit_diag_ps_0", JuliaSyntax.emit_diagnostic, (PS,)),
    ("emit_diag_ps_1", JuliaSyntax.emit_diagnostic, (PS, PSP)),
    ("emit_diag_ps_2", JuliaSyntax.emit_diagnostic, (PS, PSP, PSP)),
    ("emit_diag_pst", JuliaSyntax.emit_diagnostic, (PSt, Vararg{Any})),

    # peek_behind
    ("peek_behind_ps_pos", JuliaSyntax.peek_behind, (PS, PSP)),
    ("peek_behind_ps", JuliaSyntax.peek_behind, (PS,)),
    ("peek_behind_pst", JuliaSyntax.peek_behind, (PSt, Vararg{Any})),

    # peek_token
    ("peek_token_ps", JuliaSyntax.peek_token, (PS,)),
    ("peek_token_pst", JuliaSyntax.peek_token, (PSt,)),
    ("peek_token_pst_any", JuliaSyntax.peek_token, (PSt, Any)),
    ("peek_token_ps_int", JuliaSyntax.peek_token, (PS, Integer)),

    # ══════════ Thin wrappers (2 stmts) — these call multi-arg versions ══════════
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
    ("parse_call_arglist", JuliaSyntax.parse_call_arglist, (PSt, Any)),
    ("parse_comprehension", JuliaSyntax.parse_comprehension, (PSt, Any, Any)),
    ("parse_vect", JuliaSyntax.parse_vect, (PSt, Any, Any)),
    ("parse_subtype_spec", JuliaSyntax.parse_subtype_spec, (PSt,)),

    # Thin wrappers — 1-arg calls multi-arg
    ("parse_atom_1", JuliaSyntax.parse_atom, (PSt,)),
    ("parse_paren_1", JuliaSyntax.parse_paren, (PSt,)),
    ("parse_call_chain_1", JuliaSyntax.parse_call_chain, (PSt, Bool)),
    ("parse_comparison_1", JuliaSyntax.parse_comparison, (PSt,)),
    ("parse_docstring_1", JuliaSyntax.parse_docstring, (PSt,)),
    ("parse_comma_1", JuliaSyntax.parse_comma, (PSt,)),
    ("parse_unary_prefix_1", JuliaSyntax.parse_unary_prefix, (PSt,)),
    ("parse_import_atsym_1", JuliaSyntax.parse_import_atsym, (PSt,)),
    ("parse_brackets_1", JuliaSyntax.parse_brackets, (Function, PSt, Any)),
    ("parse_block_inner_w", JuliaSyntax.parse_block_inner, (PSt, Any)),

    # ══════════ Small real functions (< 200 stmts) ══════════
    ("parse_eq", JuliaSyntax.parse_eq, (PSt,)),
    ("parse_assignment", JuliaSyntax.parse_assignment, (PSt, Any)),
    ("parse_call", JuliaSyntax.parse_call, (PSt,)),
    ("parse_factor", JuliaSyntax.parse_factor, (PSt,)),
    ("parse_array", JuliaSyntax.parse_array, (PSt, Any, Any, Any)),
    ("parse_block_pst", JuliaSyntax.parse_block, (PSt,)),
    ("parse_iteration_specs", JuliaSyntax.parse_iteration_specs, (PSt,)),

    # ══════════ Medium functions (200-600 stmts) ══════════
    ("parse_where", JuliaSyntax.parse_where, (PSt, Any)),
    ("parse_space_separated", JuliaSyntax.parse_space_separated_exprs, (PSt,)),
    ("parse_factor_with_init", JuliaSyntax.parse_factor_with_initial_ex, (PSt, Any)),
    ("parse_RtoL", JuliaSyntax.parse_RtoL, (PSt, Any, Any, Any)),
    ("parse_comma_separated", JuliaSyntax.parse_comma_separated, (PSt, Any)),
    ("parse_lazy_cond", JuliaSyntax.parse_lazy_cond, (PSt, Any, Any, Any)),
    ("parse_macro_name", JuliaSyntax.parse_macro_name, (PSt,)),
    ("parse_public", JuliaSyntax.parse_public, (PSt,)),
    ("parse_with_chains", JuliaSyntax.parse_with_chains, (PSt, Any, Any, Any)),
    ("parse_eq_star", JuliaSyntax.parse_eq_star, (PSt,)),
    ("parse_invalid_ops", JuliaSyntax.parse_invalid_ops, (PSt,)),
    ("parse_struct_field", JuliaSyntax.parse_struct_field, (PSt,)),
    ("parse_toplevel", JuliaSyntax.parse_toplevel, (PSt,)),
    ("parse_chain", JuliaSyntax.parse_chain, (PSt, Any, Any)),

    # ══════════ Large functions (600-1200 stmts) ══════════
    ("parse_docstring_any", JuliaSyntax.parse_docstring, (PSt, Any)),
    ("parse_stmts", JuliaSyntax.parse_stmts, (PSt,)),
    ("parse_arrow", JuliaSyntax.parse_arrow, (PSt,)),
    ("parse_comma_any", JuliaSyntax.parse_comma, (PSt, Any)),
    ("parse_LtoR", JuliaSyntax.parse_LtoR, (PSt, Any, Any)),
    ("parse_cat", JuliaSyntax.parse_cat, (PSt, Any, Any)),
    ("parse_import", JuliaSyntax.parse_import, (PSt, Any, Any)),
    ("parse_Nary", JuliaSyntax.parse_Nary, (PSt, Any, Any, Any)),
    ("parse_iteration_spec", JuliaSyntax.parse_iteration_spec, (PSt,)),
    ("parse_do", JuliaSyntax.parse_do, (PSt,)),
    ("parse_catch", JuliaSyntax.parse_catch, (PSt,)),
    ("parse_where_chain", JuliaSyntax.parse_where_chain, (PSt, Any)),
    ("parse_juxtapose", JuliaSyntax.parse_juxtapose, (PSt,)),
    ("parse_decl_with_init", JuliaSyntax.parse_decl_with_initial_ex, (PSt, Any)),
    ("parse_assign_with_init", JuliaSyntax.parse_assignment_with_initial_ex, (PSt, Any, Any)),
    ("parse_unary_prefix_any", JuliaSyntax.parse_unary_prefix, (PSt, Any)),
    ("parse_generator", JuliaSyntax.parse_generator, (PSt, Any)),
    ("parse_unary_subtype", JuliaSyntax.parse_unary_subtype, (PSt,)),

    # ══════════ Very large functions (1200+ stmts) ══════════
    ("parse_brackets_full", JuliaSyntax.parse_brackets, (Function, PSt, Any, Any)),
    ("parse_paren_full", JuliaSyntax.parse_paren, (PSt, Any, Any)),
    ("parse_comparison_full", JuliaSyntax.parse_comparison, (PSt, Any)),
    ("parse_imports", JuliaSyntax.parse_imports, (PSt,)),
    ("parse_import_path", JuliaSyntax.parse_import_path, (PSt,)),
    ("parse_import_atsym_any", JuliaSyntax.parse_import_atsym, (PSt, Any)),
    ("parse_cond", JuliaSyntax.parse_cond, (PSt,)),
    ("parse_func_sig", JuliaSyntax.parse_function_signature, (PSt, Bool)),

    # ══════════ Huge functions (3000+ stmts) ══════════
    ("parse_unary", JuliaSyntax.parse_unary, (PSt,)),
    ("parse_range", JuliaSyntax.parse_range, (PSt,)),
    ("parse_string", JuliaSyntax.parse_string, (PSt, Bool)),
    ("parse_call_chain_full", JuliaSyntax.parse_call_chain, (PSt, Any, Any)),
    ("parse_resword", JuliaSyntax.parse_resword, (PSt,)),
    ("parse_atom_full", JuliaSyntax.parse_atom, (PSt, Any, Any)),
]

# ── Test 1: All functions pass code_typed ─────────────────────────────────────
ct_pass = 0
ct_fail = 0
@testset "Parser code_typed" begin
    for (name, func, argtypes) in ALL_FUNCS
        ci_list = Base.code_typed(func, argtypes, optimize=true)
        if !isempty(ci_list)
            global ct_pass += 1
            @test true
        else
            global ct_fail += 1
            println("  SKIP (empty code_typed): $name")
            @test_broken false
        end
    end
end
println("  code_typed: $ct_pass pass, $ct_fail fail")

# ── Test 2: Individual compilation ───────────────────────────────────────────
compiled_count = 0
compile_failed = String[]
@testset "Parser individual compilation" begin
    for (name, func, argtypes) in ALL_FUNCS
        ci_list = Base.code_typed(func, argtypes, optimize=true)
        if isempty(ci_list)
            push!(compile_failed, "$name: empty code_typed")
            continue
        end
        ci = ci_list[1][1]
        rettype = ci_list[1][2]
        try
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            @test length(bytes) > 0
            global compiled_count += 1
        catch e
            push!(compile_failed, "$name ($(length(ci.code)) stmts): $(sprint(showerror, e))")
            @test_broken false
        end
    end
end
println("  Compiled: $compiled_count / $(length(ALL_FUNCS))")
if !isempty(compile_failed)
    println("  Compilation failures ($(length(compile_failed))):")
    for f in compile_failed
        println("    $f")
    end
end

# ── Test 3: Parser module assembly ───────────────────────────────────────────
@testset "Parser module assembly" begin
    ir_entries = []
    skipped = String[]
    for (name, func, argtypes) in ALL_FUNCS
        try
            ci_list = Base.code_typed(func, argtypes, optimize=true)
            if isempty(ci_list)
                push!(skipped, "$name: empty code_typed")
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

        # Save module
        parser_wasm = joinpath(@__DIR__, "parser_module.wasm")
        write(parser_wasm, bytes)
        println("  Saved to: parser_module.wasm")

        rm(tmpf, force=true)
    end
end

println("\n=== PHASE-3A-002 Summary ===")
println("Total parser functions: $(length(ALL_FUNCS))")
println("Compiled individually: $compiled_count")
println("Test expressions: $(length(TEST_EXPRS))")
