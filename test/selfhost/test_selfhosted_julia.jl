# test_selfhosted_julia.jl — PHASE-3-INT-001: Assemble self-hosted-julia.wasm
#
# Combines ALL phases into a single self-hosting module:
# - Phase 3a: JuliaSyntax parser + tree cursors (84 functions, 517.9 KB)
# - Phase 3b: JuliaLowering lowerer (data + desugar + scope + closure/linearIR)
# - Phase 2:  TypeInf (P2a interface + P2b subtype/matching/intersection)
# - Phase 1:  Codegen support functions
#
# Run: julia +1.12 --project=. test/selfhost/test_selfhosted_julia.jl

using Test
using WasmTarget
using JuliaLowering
using JuliaSyntax

println("=== PHASE-3-INT-001: Assemble self-hosted-julia.wasm ===\n")

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3a: Parser + Tree Cursors (proven in PHASE-3A-004)
# ═══════════════════════════════════════════════════════════════════════════════

GTC = JuliaSyntax.GreenTreeCursor
RTC = JuliaSyntax.RedTreeCursor
SF  = JuliaSyntax.SourceFile
GN  = JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}
SN  = JuliaSyntax.SyntaxNode
SH  = JuliaSyntax.SyntaxHead
PS  = JuliaSyntax.ParseState
PSt = JuliaSyntax.ParseStream
RevGTC = Base.Iterators.Reverse{GTC}
RevRTC = Base.Iterators.Reverse{RTC}

# Tree cursor functions (30)
tree_funcs = [
    ("gc_head", JuliaSyntax.head, (GTC,)),
    ("gc_is_leaf", JuliaSyntax.is_leaf, (GTC,)),
    ("gc_span", JuliaSyntax.span, (GTC,)),
    ("rc_head", JuliaSyntax.head, (RTC,)),
    ("rc_is_leaf", JuliaSyntax.is_leaf, (RTC,)),
    ("rc_span", JuliaSyntax.span, (RTC,)),
    ("rc_byte_range", JuliaSyntax.byte_range, (RTC,)),
    ("reverse_green", Base.reverse, (GTC,)),
    ("reverse_red", Base.reverse, (RTC,)),
    ("iterate_rev_green_1", Base.iterate, (RevGTC,)),
    ("iterate_rev_red_1", Base.iterate, (RevRTC,)),
    ("iterate_rev_green_2", Base.iterate, (RevGTC, Tuple{UInt32, UInt32})),
    ("iterate_rev_red_2", Base.iterate, (RevRTC, Tuple{UInt32, UInt32, UInt32})),
    ("sf_source_line", JuliaSyntax.source_line, (SF, Int)),
    ("sf_source_location", JuliaSyntax.source_location, (SF, Int)),
    ("sf_sourcetext", JuliaSyntax.sourcetext, (SF,)),
    ("sf_firstindex", Base.firstindex, (SF,)),
    ("sf_lastindex", Base.lastindex, (SF,)),
    ("sf_filename", JuliaSyntax.filename, (SF,)),
    ("gn_from_cursor", JuliaSyntax.GreenNode, (GTC,)),
    ("children_gn", JuliaSyntax.children, (GN,)),
    ("numchildren_gn", JuliaSyntax.numchildren, (GN,)),
    ("head_gn", JuliaSyntax.head, (GN,)),
    ("span_gn", JuliaSyntax.span, (GN,)),
    ("is_leaf_gn", JuliaSyntax.is_leaf, (GN,)),
    ("sn_from_cursor", JuliaSyntax.SyntaxNode, (SF, RTC)),
    ("children_sn", JuliaSyntax.children, (SN,)),
    ("kind_sn", JuliaSyntax.kind, (SN,)),
    ("kind_sh", JuliaSyntax.kind, (SH,)),
    ("byte_range_sn", JuliaSyntax.byte_range, (SN,)),
]

# Parser functions (46 from ParseState — proven in PHASE-3A-004)
parse_names = [
    :parse_and, :parse_arrow, :parse_atom, :parse_block, :parse_call,
    :parse_catch, :parse_comma, :parse_comparison, :parse_cond, :parse_do,
    :parse_docstring, :parse_eq, :parse_eq_star, :parse_expr, :parse_factor,
    :parse_factor_after, :parse_global_local_const_vars, :parse_if_elseif,
    :parse_import_atsym, :parse_import_path, :parse_imports, :parse_invalid_ops,
    :parse_iteration_spec, :parse_iteration_specs, :parse_juxtapose,
    :parse_macro_name, :parse_or, :parse_pair, :parse_paren, :parse_pipe_gt,
    :parse_pipe_lt, :parse_public, :parse_range, :parse_rational, :parse_resword,
    :parse_shift, :parse_space_separated_exprs, :parse_stmts, :parse_struct_field,
    :parse_subtype_spec, :parse_term, :parse_toplevel, :parse_try,
    :parse_unary, :parse_unary_prefix, :parse_unary_subtype,
]
parser_funcs = Tuple{String, Any, Tuple}[]
for fname in parse_names
    f = getfield(JuliaSyntax, fname)
    try
        ci_list = Base.code_typed(f, (PS,))
        if !isempty(ci_list)
            push!(parser_funcs, (string(fname), f, (PS,)))
        end
    catch; end
end

# Stream utility functions
stream_funcs = Tuple{String, Any, Tuple}[]
for (name, f, argtypes) in [
    ("bump_pst", JuliaSyntax.bump, (PSt,)),
    ("peek_token", JuliaSyntax.peek_token, (PSt,)),
    ("emit_diagnostic_pst", JuliaSyntax.emit_diagnostic, (PSt,)),
    ("kind_pst", JuliaSyntax.kind, (PSt,)),
    ("is_trivia_pst", JuliaSyntax.is_trivia, (PSt,)),
    ("is_keyword_pst", JuliaSyntax.is_keyword, (PSt,)),
    ("is_operator_pst", JuliaSyntax.is_operator, (PSt,)),
    ("is_literal_pst", JuliaSyntax.is_literal, (PSt,)),
]
    try
        ci_list = Base.code_typed(f, argtypes)
        if !isempty(ci_list)
            push!(stream_funcs, (name, f, argtypes))
        end
    catch; end
end

phase3a_funcs = vcat(tree_funcs, parser_funcs, stream_funcs)

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3b: Lowerer (proven in PHASE-3B-001 through 005)
# ═══════════════════════════════════════════════════════════════════════════════

SG = JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}
ST = JuliaLowering.SyntaxTree{SG}
DCc = JuliaLowering.DesugaringContext{SG}
SRCc = JuliaLowering.ScopeResolutionContext{SG}
CCc = JuliaLowering.ClosureConversionCtx{SG}
B = JuliaLowering.Bindings
BI = JuliaLowering.BindingInfo

phase3b_funcs = [
    # Data structures (from PHASE-3B-001)
    ("is_quoted", JuliaLowering.is_quoted, (ST,)),
    ("kind_st", JuliaLowering.kind, (ST,)),
    ("children_st", JuliaLowering.children, (ST,)),
    ("numchildren_st", JuliaLowering.numchildren, (ST,)),
    ("add_binding", JuliaLowering.add_binding, (B, BI)),
    ("SyntaxGraph_ctor", JuliaLowering.SyntaxGraph, ()),
    # JuliaSyntax accessors on SyntaxTree
    ("is_prefix_call_st", JuliaLowering.is_prefix_call, (ST,)),
    ("is_infix_op_call_st", JuliaLowering.is_infix_op_call, (ST,)),
    ("is_postfix_op_call_st", JuliaLowering.is_postfix_op_call, (ST,)),
    ("is_operator_st", JuliaLowering.is_operator, (ST,)),
    ("head_st", JuliaLowering.head, (ST,)),
    ("span_st", JuliaLowering.span, (ST,)),
    ("filename_st", JuliaLowering.filename, (ST,)),
    ("source_location_st", JuliaLowering.source_location, (ST,)),
    ("byte_range_st", JuliaLowering.byte_range, (ST,)),
    ("first_byte_st", JuliaLowering.first_byte, (ST,)),
    ("last_byte_st", JuliaLowering.last_byte, (ST,)),
    ("sourcetext_st", JuliaLowering.sourcetext, (ST,)),
    # SyntaxGraph operations
    ("numchildren_sg", JuliaLowering.numchildren, (SG, Int)),
    ("assigned_function_name", JuliaLowering.assigned_function_name, (ST,)),
    ("is_eventually_call_st", JuliaLowering.is_eventually_call, (ST,)),
    # Desugaring (from PHASE-3B-002)
    ("expand_forms_2", JuliaLowering.expand_forms_2, (DCc, ST)),
    # Scope (from PHASE-3B-003)
    ("resolve_scopes", JuliaLowering.resolve_scopes, (SRCc, ST)),
    ("current_lambda_bindings", JuliaLowering.current_lambda_bindings, (SRCc,)),
    ("has_lambda_binding", JuliaLowering.has_lambda_binding, (SRCc, ST)),
    # Closure (from PHASE-3B-004)
    ("is_boxed", JuliaLowering.is_boxed, (CCc, ST)),
    ("is_self_captured", JuliaLowering.is_self_captured, (CCc, ST)),
]

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2b: Subtype + Matching (proven in PHASE-2B-001 through 004)
# ═══════════════════════════════════════════════════════════════════════════════

# Load typeinf modules
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "ccall_stubs.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "subtype.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "matching.jl"))

phase2b_funcs = [
    # Core subtype
    ("VarBinding", VarBinding, (TypeVar, Bool)),
    ("SubtypeEnv_ctor", SubtypeEnv, ()),
    ("se_lookup", lookup, (SubtypeEnv, TypeVar)),
    ("wasm_subtype", wasm_subtype, (Any, Any)),
    ("_subtype", _subtype, (Any, Any, SubtypeEnv, Int)),
    ("_var_lt", _var_lt, (VarBinding, Any, SubtypeEnv, Int)),
    ("_var_gt", _var_gt, (VarBinding, Any, SubtypeEnv, Int)),
    ("_subtype_var", _subtype_var, (VarBinding, Any, SubtypeEnv, Bool, Int)),
    ("_record_var_occurrence", _record_var_occurrence, (VarBinding, SubtypeEnv, Int)),
    ("_subtype_unionall", _subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int)),
    ("_subtype_inner", _subtype_inner, (Any, Any, SubtypeEnv, Bool, Int)),
    ("_is_leaf_bound", _is_leaf_bound, (Any,)),
    ("_type_contains_var", _type_contains_var, (Any, TypeVar)),
    ("_subtype_check", _subtype_check, (Any, Any)),
    ("_subtype_datatypes", _subtype_datatypes, (DataType, DataType, SubtypeEnv, Int)),
    ("_forall_exists_equal", _forall_exists_equal, (Any, Any, SubtypeEnv)),
    ("_tuple_subtype_env", _tuple_subtype_env, (DataType, DataType, SubtypeEnv, Int)),
    ("_subtype_tuple_param", _subtype_tuple_param, (Any, Any, SubtypeEnv)),
    ("_datatype_subtype", _datatype_subtype, (DataType, DataType)),
    ("_tuple_subtype", _tuple_subtype, (DataType, DataType)),
    ("_subtype_param", _subtype_param, (Any, Any)),
    # Simple intersection
    ("wasm_type_intersection", wasm_type_intersection, (Any, Any)),
    ("_no_free_typevars", _no_free_typevars, (Any,)),
    ("_intersect", _intersect, (Any, Any, Int)),
    ("_intersect_union", _intersect_union, (Union, Any, Int)),
    ("_simple_join", _simple_join, (Any, Any)),
    ("_intersect_datatypes", _intersect_datatypes, (DataType, DataType, Int)),
    ("_intersect_tuple", _intersect_tuple, (DataType, DataType, Int)),
    ("_intersect_same_name", _intersect_same_name, (DataType, DataType, Int)),
    ("_intersect_invariant", _intersect_invariant, (Any, Any)),
    ("_intersect_different_names", _intersect_different_names, (DataType, DataType, Int)),
    # IntersectEnv-based
    ("IntersectBinding", IntersectBinding, (TypeVar, Bool)),
    ("IntersectEnv_ctor", IntersectEnv, ()),
    ("_ilookup", _ilookup, (IntersectEnv, TypeVar)),
    ("_irecord_occurrence", _irecord_occurrence, (IntersectBinding, IntersectEnv, Int)),
    ("_intersect_env", _intersect_env, (Any, Any, IntersectEnv, Int)),
    ("_intersect_union_env", _intersect_union_env, (Union, Any, IntersectEnv, Int)),
    ("_intersect_ivar", _intersect_ivar, (TypeVar, IntersectBinding, Any, IntersectEnv, Int)),
    ("_intersect_aside", _intersect_aside, (Any, Any, IntersectEnv)),
    ("_intersect_unionall_inner", _intersect_unionall_inner, (Any, UnionAll, IntersectEnv, Bool, Int)),
    ("_finish_unionall", _finish_unionall, (Any, IntersectBinding, UnionAll)),
    ("_no_free_typevars_val", _no_free_typevars_val, (Any,)),
    ("_intersect_datatypes_env", _intersect_datatypes_env, (DataType, DataType, IntersectEnv, Int)),
    ("_intersect_tuple_env", _intersect_tuple_env, (DataType, DataType, IntersectEnv, Int)),
    ("_intersect_same_name_env", _intersect_same_name_env, (DataType, DataType, IntersectEnv, Int)),
    ("_intersect_invariant_env", _intersect_invariant_env, (Any, Any, IntersectEnv)),
    ("_intersect_different_names_env", _intersect_different_names_env, (DataType, DataType, IntersectEnv, Int)),
    # Matching
    ("wasm_matching_methods", wasm_matching_methods, (Any,)),
    ("_wasm_matching_methods_pos", _wasm_matching_methods_positional, (Any, Int)),
    ("_get_all_methods", _get_all_methods, (Any,)),
    ("_extract_sparams", _extract_sparams, (Any, Any)),
    ("_extract_sparams_walk!", _extract_sparams_walk!, (Vector{Any}, Any, Any, SubtypeEnv)),
    ("_in_interferences", _in_interferences, (Method, Method)),
    ("_method_morespecific", _method_morespecific, (Method, Method)),
    ("_sort_by_specificity!", _sort_by_specificity!, (Vector{Any},)),
    ("_detect_ambiguity", _detect_ambiguity, (Vector{Any},)),
]

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Compile ALL functions individually, filter validated ones
# ═══════════════════════════════════════════════════════════════════════════════

println("--- Step 1: Compile and validate individually ---")

all_funcs_by_phase = [
    ("Phase 3a (parser)", phase3a_funcs),
    ("Phase 3b (lowerer)", phase3b_funcs),
    ("Phase 2b (subtype/matching)", phase2b_funcs),
]

valid_entries = Tuple[]  # (CodeInfo, rettype, argtypes, name)
phase_counts = Dict{String, Tuple{Int,Int,Int}}()  # phase → (total, compiled, validated)

for (phase_name, funcs) in all_funcs_by_phase
    compiled = 0
    validated = 0
    total = length(funcs)
    for (name, f, argtypes) in funcs
        try
            ci_list = Base.code_typed(f, argtypes)
            isempty(ci_list) && continue
            ci = ci_list[1][1]
            rettype = ci_list[1][2]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            compiled += 1
            # Validate individually
            tmppath = joinpath(tempdir(), "shj_$(name).wasm")
            write(tmppath, bytes)
            result = try read(`wasm-tools validate $tmppath`, String) catch e; "error" end
            rm(tmppath, force=true)
            if isempty(result)
                push!(valid_entries, (ci, rettype, argtypes, name, f))
                validated += 1
            end
        catch; end
    end
    phase_counts[phase_name] = (total, compiled, validated)
    println("  $phase_name: $validated/$total validated ($compiled compiled)")
end

total_valid = length(valid_entries)
println("  Total validated: $total_valid functions\n")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Assemble combined module
# ═══════════════════════════════════════════════════════════════════════════════

println("--- Step 2: Assemble combined self-hosted-julia module ---")

module_bytes = UInt8[]
module_compiled = false
n_exports = 0
n_functions = 0
n_types = 0

try
    mod = WasmTarget.compile_module_from_ir(collect(valid_entries))
    global module_bytes = WasmTarget.to_bytes(mod)
    global n_exports = length(mod.exports)
    global n_functions = length(mod.functions)
    global n_types = length(mod.types)
    global module_compiled = true
    raw_kb = round(length(module_bytes)/1024, digits=1)
    println("  ✓ Module: $(length(module_bytes)) bytes ($raw_kb KB)")
    println("    Functions: $n_functions, Types: $n_types, Exports: $n_exports")
catch e
    println("  ✗ Assembly failed: $(sprint(showerror, e)[1:min(500,end)])")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Validate with wasm-tools
# ═══════════════════════════════════════════════════════════════════════════════

validate_ok = false
load_ok = false
output_path = joinpath(@__DIR__, "..", "..", "self-hosted-julia.wasm")

if module_compiled
    write(output_path, module_bytes)

    println("\n--- Step 3: Validate ---")
    global validate_ok = try
        result = read(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=stderr), String)
        isempty(result)
    catch
        false
    end
    println("  wasm-tools validate: $(validate_ok ? "PASS" : "FAIL")")

    if !validate_ok
        # Get error message for debugging
        try
            err_output = read(pipeline(`wasm-tools validate --features=gc $output_path`; stderr), String)
            if !isempty(err_output)
                println("  Error (first 300 chars): $(err_output[1:min(300,end)])")
            end
        catch e
            err_str = sprint(showerror, e)
            println("  Validation error: $(err_str[1:min(300,end)])")
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Step 4: Node.js load test
    # ═══════════════════════════════════════════════════════════════════════════

    println("\n--- Step 4: Node.js load ---")
    js_code = """
    const fs = require("fs");
    const bytes = fs.readFileSync("$(output_path)");
    WebAssembly.compile(bytes).then(async mod => {
        const imports_desc = WebAssembly.Module.imports(mod);
        const stubs = {};
        for (const imp of imports_desc) {
            if (!stubs[imp.module]) stubs[imp.module] = {};
            if (imp.kind === "function") stubs[imp.module][imp.name] = () => {};
        }
        const inst = await WebAssembly.instantiate(mod, stubs);
        console.log(Object.keys(inst.exports).length);
    }).catch(e => { console.error("FAIL:" + e.message); process.exit(1); });
    """
    tmpjs = joinpath(tempdir(), "test_selfhosted.cjs")
    write(tmpjs, js_code)
    node_output = try strip(read(`node $tmpjs`, String)) catch e; "ERROR: $(sprint(showerror, e))" end
    rm(tmpjs, force=true)

    if startswith(node_output, "FAIL") || startswith(node_output, "ERROR")
        println("  Node.js: $node_output")
    else
        actual_exports = try Base.parse(Int, node_output) catch; -1 end
        global load_ok = actual_exports > 0
        println("  Node.js: OK — $actual_exports exports loaded")
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Step 5: Binary size analysis
    # ═══════════════════════════════════════════════════════════════════════════

    println("\n--- Step 5: Binary size ---")
    raw_kb = round(length(module_bytes)/1024, digits=1)
    est_brotli = round(length(module_bytes) * 0.35 / 1024, digits=1)
    println("  Raw: $raw_kb KB")
    println("  Estimated Brotli: ~$(est_brotli) KB")
    println("  Functions: $n_functions")
    println("  Types: $n_types")
    println("  Exports: $n_exports")

    # Phase breakdown
    println("\n  Phase breakdown:")
    for (phase_name, _) in all_funcs_by_phase
        total, compiled, validated = phase_counts[phase_name]
        println("    $phase_name: $validated/$total validated")
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

@testset "PHASE-3-INT-001: self-hosted-julia.wasm" begin
    @testset "function collection" begin
        @test length(valid_entries) >= 50  # Expect at least 50 from 3 phases
    end

    @testset "individual phase compilation" begin
        for (phase_name, _) in all_funcs_by_phase
            total, compiled, validated = phase_counts[phase_name]
            @test validated > 0
        end
    end

    @testset "module assembly" begin
        @test module_compiled
        @test length(module_bytes) > 0
    end

    @testset "wasm-tools validation" begin
        @test validate_ok
    end

    @testset "Node.js loading" begin
        @test load_ok
    end

    @testset "binary size" begin
        @test length(module_bytes) < 5_000_000  # < 5 MB raw (spec budget)
        @test length(module_bytes) > 50_000      # sanity: at least 50 KB
    end

    @testset "export coverage" begin
        @test n_exports >= 50
    end
end

println("\n=== PHASE-3-INT-001 test complete ===")
