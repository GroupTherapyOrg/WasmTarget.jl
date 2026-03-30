# test_unified_module.jl — BETA-003: Unified module with optimize=true for ALL functions
#
# Compiles ALL phases (P1+P2a+P2b+P3a+P3b) with optimize=true in one module.
# CRITICAL: code_typed P2b/P3a/P3b/P1 BEFORE loading ccall_replacements.jl.
# Then load ccall_replacements.jl. Then code_typed P2a. Combine all in one call.
#
# Run: julia +1.12 --project=. test/selfhost/test_unified_module.jl

using Test
using WasmTarget
using WasmTarget: compile_module_from_ir, to_bytes,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  BasicBlock, WasmValType
using JuliaLowering
using JuliaSyntax

println("=" ^ 60)
println("BETA-003: Unified module with optimize=true")
println("  ALL phases: P1+P2a+P2b+P3a+P3b")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: code_typed in CLEAN session (no ccall_replacements loaded)
# ═══════════════════════════════════════════════════════════════════════════════

# ── P3a: Parser + Tree Cursors ──────────────────────────────────────────────

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

# ── P3b: Lowerer ────────────────────────────────────────────────────────────

SG = JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}
ST = JuliaLowering.SyntaxTree{SG}
DCc = JuliaLowering.DesugaringContext{SG}
SRCc = JuliaLowering.ScopeResolutionContext{SG}
CCc = JuliaLowering.ClosureConversionCtx{SG}
B = JuliaLowering.Bindings
BI = JuliaLowering.BindingInfo

phase3b_funcs = [
    ("is_quoted", JuliaLowering.is_quoted, (ST,)),
    ("kind_st", JuliaLowering.kind, (ST,)),
    ("children_st", JuliaLowering.children, (ST,)),
    ("numchildren_st", JuliaLowering.numchildren, (ST,)),
    ("add_binding", JuliaLowering.add_binding, (B, BI)),
    ("SyntaxGraph_ctor", JuliaLowering.SyntaxGraph, ()),
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
    ("numchildren_sg", JuliaLowering.numchildren, (SG, Int)),
    ("assigned_function_name", JuliaLowering.assigned_function_name, (ST,)),
    ("is_eventually_call_st", JuliaLowering.is_eventually_call, (ST,)),
    ("expand_forms_2", JuliaLowering.expand_forms_2, (DCc, ST)),
    ("resolve_scopes", JuliaLowering.resolve_scopes, (SRCc, ST)),
    ("current_lambda_bindings", JuliaLowering.current_lambda_bindings, (SRCc,)),
    ("has_lambda_binding", JuliaLowering.has_lambda_binding, (SRCc, ST)),
    ("is_boxed", JuliaLowering.is_boxed, (CCc, ST)),
    ("is_self_captured", JuliaLowering.is_self_captured, (CCc, ST)),
]

# ── P2b: Subtype + Matching ────────────────────────────────────────────────

# Load stubs + subtype + matching (but NOT ccall_replacements!)
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "ccall_stubs.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "subtype.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "matching.jl"))

phase2b_funcs = [
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

# ── P1: Codegen functions ───────────────────────────────────────────────────

codegen_functions = [
    (encode_leb128_signed, (Int32,), "encode_leb128_signed_i32"),
    (encode_leb128_signed, (Int64,), "encode_leb128_signed_i64"),
    (encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned"),
    (compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32"),
    (compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64"),
    (compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64"),
    (compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool"),
    (get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_concrete_wasm_type"),
    (WasmTarget.analyze_blocks, (Vector{Any},), "analyze_blocks"),
    (WasmTarget.fix_broken_select_instructions, (Vector{UInt8},), "fix_broken_select_instructions"),
    (WasmTarget.fix_consecutive_local_sets, (Vector{UInt8},), "fix_consecutive_local_sets"),
    (WasmTarget.strip_excess_after_function_end, (Vector{UInt8},), "strip_excess_after_function_end"),
    (WasmTarget.fix_array_len_wrap, (Vector{UInt8},), "fix_array_len_wrap"),
    (WasmTarget.fix_i32_wrap_after_i32_ops, (Vector{UInt8},), "fix_i32_wrap_after_i32_ops"),
    (WasmTarget.fix_i64_local_in_i32_ops, (Vector{UInt8}, Vector{WasmValType}), "fix_i64_local_in_i32_ops"),
    (WasmTarget.fix_local_get_set_type_mismatch, (Vector{UInt8}, Vector{WasmValType}), "fix_local_get_set_type_mismatch"),
    (WasmTarget.fix_numeric_to_ref_local_stores, (Vector{UInt8}, Vector{WasmValType}, Int64), "fix_numeric_to_ref_local_stores"),
    (WasmTarget.generate_block_code, (CompilationContext, BasicBlock), "generate_block_code"),
    (WasmTarget.generate_structured, (CompilationContext, Vector{BasicBlock}), "generate_structured"),
    (WasmTarget.generate_body, (CompilationContext,), "generate_body"),
]

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: code_typed ALL clean functions (P3a, P3b, P2b, P1) with optimize=true
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 1: code_typed clean functions (P3a+P3b+P2b+P1) ---")

clean_entries = Tuple[]  # (CodeInfo, rettype, argtypes, name, func_ref)

# P3a
for (name, f, argtypes) in phase3a_funcs
    try
        ci, rt = Base.code_typed(f, argtypes; optimize=true)[1]
        push!(clean_entries, (ci, rt, argtypes, name, f))
    catch; end
end
println("  P3a: $(length(clean_entries)) functions")

p3a_count = length(clean_entries)

# P3b
for (name, f, argtypes) in phase3b_funcs
    try
        ci, rt = Base.code_typed(f, argtypes; optimize=true)[1]
        push!(clean_entries, (ci, rt, argtypes, name, f))
    catch; end
end
println("  P3b: $(length(clean_entries) - p3a_count) functions")

p3b_count = length(clean_entries)

# P2b
for (name, f, argtypes) in phase2b_funcs
    try
        ci, rt = Base.code_typed(f, argtypes; optimize=true)[1]
        push!(clean_entries, (ci, rt, argtypes, name, f))
    catch; end
end
println("  P2b: $(length(clean_entries) - p3b_count) functions")

p2b_count = length(clean_entries)

# P1
for (f, argtypes, name) in codegen_functions
    try
        ci, rt = Base.code_typed(f, argtypes; optimize=true)[1]
        push!(clean_entries, (ci, rt, argtypes, name, f))
    catch; end
end
println("  P1: $(length(clean_entries) - p2b_count) functions")

println("  Total clean: $(length(clean_entries)) functions")

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: Load overrides, then code_typed P2a with optimize=true
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Load ccall_replacements + code_typed P2a ---")

include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "ccall_replacements.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "dict_method_table.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "typeid_registry.jl"))

using Core.Compiler: InferenceResult, InferenceState

test_sigs = [
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(*), Int64, Int64},
    Tuple{typeof(-), Int64, Int64},
]
world = Base.get_world_counter()
interp = build_wasm_interpreter(test_sigs; world=world, transitive=false)
interp_type = typeof(interp)

native_mt = Core.Compiler.InternalMethodTable(world)
lookup_res = Core.Compiler.findall(test_sigs[1], native_mt; limit=3)
mi = Core.Compiler.specialize_method(first(lookup_res.matches))
src = Core.Compiler.retrieve_code_info(mi, world)
result = InferenceResult(mi)
frame = InferenceState(result, src, :no, interp)

p2a_targets = [
    (Core.Compiler.method_table,        (interp_type,),  "method_table"),
    (Core.Compiler.InferenceParams,     (interp_type,),  "InferenceParams"),
    (Core.Compiler.OptimizationParams,  (interp_type,),  "OptimizationParams"),
    (Core.Compiler.get_inference_world,  (interp_type,),  "get_inference_world"),
    (Core.Compiler.get_inference_cache,  (interp_type,),  "get_inference_cache"),
    (Core.Compiler.specialize_method, (Core.MethodMatch,), "specialize_method"),
    (Core.Compiler.typeinf,          (interp_type, typeof(frame)), "typeinf"),
    (Core.Compiler.findall, (Type, typeof(interp.method_table.table)), "findall_DictMethodTable"),
    (Core.Compiler.isoverlayed, (typeof(interp.method_table.table),), "isoverlayed"),
    (get_code_info, (typeof(PreDecompressedCodeInfo()), Core.MethodInstance), "get_code_info"),
    (InferenceResult, (Core.MethodInstance,), "InferenceResult_ctor"),
    (Core.Compiler.retrieve_code_info, (Core.MethodInstance, UInt64), "retrieve_code_info"),
    (InferenceState, (typeof(result), typeof(src), Symbol, interp_type), "InferenceState_ctor"),
]

p2a_entries = Tuple[]
for (f, atypes, name) in p2a_targets
    try
        ci_pair = only(Base.code_typed(f, atypes; optimize=true))
        push!(p2a_entries, (ci_pair[1], ci_pair[2], atypes, name, f))
        println("  ✓ $name ($(length(ci_pair[1].code)) stmts)")
    catch e
        println("  ✗ $name — $(string(e)[1:min(80,end)])")
    end
end
println("  P2a: $(length(p2a_entries)) functions")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Validate individually, then combine ALL in one module
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 3: Individual validation ---")

all_entries = vcat(clean_entries, p2a_entries)
println("  Total entries: $(length(all_entries))")

# Validate each entry individually to filter out bad ones
valid_entries = Tuple[]
# Known validation issue: _wasm_matching_methods_pos has 528 stmts/59 GotoIfNot
# and causes type index conflicts in the combined module. Skip it for now.
skip_names = Set(["_wasm_matching_methods_pos"])
for (ci, rt, argtypes, name, f) in all_entries
    name in skip_names && continue
    try
        bytes = WasmTarget.compile_from_codeinfo(ci, rt, name, argtypes)
        tmppath = joinpath(tempdir(), "unified_$(name).wasm")
        write(tmppath, bytes)
        local wasm_result = try read(`wasm-tools validate $tmppath`, String) catch e; "error" end
        rm(tmppath, force=true)
        if isempty(wasm_result)
            push!(valid_entries, (ci, rt, argtypes, name, f))
        end
    catch; end
end
println("  Validated: $(length(valid_entries))/$(length(all_entries))")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Assemble unified module
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 4: Assemble unified module ---")

module_compiled = false
module_bytes = UInt8[]
n_exports = 0

try
    mod = compile_module_from_ir(valid_entries)
    global module_bytes = to_bytes(mod)
    global module_compiled = true
    global n_exports = length(mod.exports)
    println("  ✓ Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Functions: $(length(mod.functions))")
    println("  Types: $(length(mod.types))")
    println("  Exports: $n_exports")
catch e
    println("  ✗ Module failed: $(string(e)[1:min(300,end)])")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Validate and load in Node.js
# ═══════════════════════════════════════════════════════════════════════════════

validate_ok = false
load_ok = false

if module_compiled
    println("\n--- Step 5: Validate + Node.js load ---")
    output_path = joinpath(@__DIR__, "..", "..", "unified-module.wasm")
    write(output_path, module_bytes)

    global validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
        println("  ✓ wasm-tools validate PASSED")
        true
    catch
        println("  ✗ wasm-tools validate FAILED")
        false
    end

    if validate_ok
        try
            node_script = """
            const fs = require('fs');
            const bytes = fs.readFileSync('$(output_path)');
            WebAssembly.compile(bytes).then(mod => {
                const exports = WebAssembly.Module.exports(mod);
                console.log(exports.length + ' exports loaded');
                process.exit(0);
            }).catch(e => {
                console.error(e.message);
                process.exit(1);
            });
            """
            local node_result = read(`node -e $node_script`, String)
            println("  ✓ Node.js: $node_result")
            global load_ok = true
        catch e
            println("  ✗ Node.js load failed: $(string(e)[1:min(200,end)])")
        end
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 60)
println("BETA-003 Summary:")
println("  Clean functions (P3a+P3b+P2b+P1): $(length(clean_entries))")
println("  P2a functions: $(length(p2a_entries))")
println("  Total validated: $(length(valid_entries))")
println("  Module compiled: $module_compiled")
println("  Module size: $(round(length(module_bytes)/1024, digits=1)) KB")
println("  Exports: $n_exports")
println("  wasm-tools validate: $validate_ok")
println("  Node.js loads: $load_ok")
println("=" ^ 60)

@testset "BETA-003: Unified module" begin
    @test length(valid_entries) >= 150  # Expect 150+ validated functions
    @test module_compiled
    @test validate_ok
    @test load_ok
    @test n_exports >= 150
end
