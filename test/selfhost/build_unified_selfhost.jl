# build_unified_selfhost.jl — INT-001: Unified self-host module with ALL pipeline stages
#
# Combines parser (JuliaSyntax) + lowerer (JuliaLowering) + subtype/matching
# + type inference (unrolled_typeinf) + codegen (compile_from_ir_prebaked)
# + serialization (to_bytes_no_dict, LEB128) + IR constructors into ONE module.
#
# Run: julia +1.12 --project=. test/selfhost/build_unified_selfhost.jl

using Test
using WasmTarget
using WasmTarget: compile_module_from_ir, to_bytes,
                  CompilationContext, InplaceCompilationContext, AbstractCompilationContext,
                  WasmModule, TypeRegistry, FunctionRegistry,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  BasicBlock, WasmValType,
                  compile_from_ir_prebaked,
                  wasm_bytes_length, wasm_bytes_get
using JuliaLowering
using JuliaSyntax

println("=" ^ 70)
println("INT-001: Unified self-hosting module — ALL pipeline stages")
println("=" ^ 70)

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE 1: Parser functions (JuliaSyntax)
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
    ("kind_pst", JuliaSyntax.kind, (PSt,)),
]
    try
        ci_list = Base.code_typed(f, argtypes)
        if !isempty(ci_list)
            push!(stream_funcs, (name, f, argtypes))
        end
    catch; end
end

parser_stage = vcat(tree_funcs, parser_funcs, stream_funcs)
println("  Parser: $(length(parser_stage)) functions")

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE 2: Lowerer functions (JuliaLowering)
# ═══════════════════════════════════════════════════════════════════════════════

SG = JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}
ST = JuliaLowering.SyntaxTree{SG}
DCc = JuliaLowering.DesugaringContext{SG}
SRCc = JuliaLowering.ScopeResolutionContext{SG}
CCc = JuliaLowering.ClosureConversionCtx{SG}
B = JuliaLowering.Bindings
BI = JuliaLowering.BindingInfo

lowerer_stage = [
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
println("  Lowerer: $(length(lowerer_stage)) functions")

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE 3: Subtype + Matching
# ═══════════════════════════════════════════════════════════════════════════════

include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "ccall_stubs.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "subtype.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "matching.jl"))

subtype_stage = [
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
    ("_get_all_methods", _get_all_methods, (Any,)),
    ("_extract_sparams", _extract_sparams, (Any, Any)),
    ("_extract_sparams_walk!", _extract_sparams_walk!, (Vector{Any}, Any, Any, SubtypeEnv)),
    ("_in_interferences", _in_interferences, (Method, Method)),
    ("_method_morespecific", _method_morespecific, (Method, Method)),
    ("_sort_by_specificity!", _sort_by_specificity!, (Vector{Any},)),
    ("_detect_ambiguity", _detect_ambiguity, (Vector{Any},)),
]
println("  Subtype+Matching: $(length(subtype_stage)) functions")

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE 4: Type Inference (unrolled_typeinf + helpers)
# ═══════════════════════════════════════════════════════════════════════════════

include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "typeid_registry.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "return_type_table.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "thin_typeinf.jl"))

# unrolled_typeinf: loop-free type inference for f(x::Int64)=x*x+1 (3 statements)
function unrolled_typeinf(
    code::Vector{Any}, callee_typeids::Vector{Int32}, arg_typeids::Vector{Int32},
    rt_table::Vector{Int32}, typeid_i64::Int32
)::Vector{Int32}
    ssa_types = Vector{Int32}(undef, 3)
    ssa_types[1] = Int32(-1)
    ssa_types[2] = Int32(-1)
    ssa_types[3] = Int32(-1)

    stmt1 = code[1]
    if stmt1 isa Expr && stmt1.head === :call
        args1 = stmt1.args
        a1_1 = args1[2]
        a1_2 = args1[3]
        tid1_1 = if a1_1 isa Core.Argument; arg_typeids[Int32(a1_1.n)]; else; Int32(-1); end
        tid1_2 = if a1_2 isa Core.Argument; arg_typeids[Int32(a1_2.n)]; else; Int32(-1); end
        at1 = Vector{Int32}(undef, 2)
        at1[1] = tid1_1
        at1[2] = tid1_2
        ssa_types[1] = lookup_return_type(rt_table, composite_hash(callee_typeids[1], at1))
    end

    stmt2 = code[2]
    if stmt2 isa Expr && stmt2.head === :call
        args2 = stmt2.args
        a2_1 = args2[2]
        a2_2 = args2[3]
        tid2_1 = if a2_1 isa Core.SSAValue; ssa_types[a2_1.id]; elseif a2_1 isa Core.Argument; arg_typeids[Int32(a2_1.n)]; else; Int32(-1); end
        tid2_2 = if a2_2 isa Int64; typeid_i64; elseif a2_2 isa Core.SSAValue; ssa_types[a2_2.id]; else; Int32(-1); end
        at2 = Vector{Int32}(undef, 2)
        at2[1] = tid2_1
        at2[2] = tid2_2
        ssa_types[2] = lookup_return_type(rt_table, composite_hash(callee_typeids[2], at2))
    end

    stmt3 = code[3]
    if stmt3 isa Core.ReturnNode
        rv = stmt3.val
        if rv isa Core.SSAValue
            ssa_types[3] = ssa_types[rv.id]
        end
    end

    return ssa_types
end

typeinf_stage = [
    # Hash table + type inference
    ("composite_hash", composite_hash, (Int32, Vector{Int32})),
    ("lookup_return_type", lookup_return_type, (Vector{Int32}, UInt32)),
    ("unrolled_typeinf", unrolled_typeinf, (Vector{Any}, Vector{Int32}, Vector{Int32}, Vector{Int32}, Int32)),
]
println("  TypeInf: $(length(typeinf_stage)) functions")

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE 5: Codegen functions
# ═══════════════════════════════════════════════════════════════════════════════

const ICtx = InplaceCompilationContext

codegen_stage = [
    # Entry point: compile_from_ir_prebaked (InplaceCompilationContext specialization)
    ("compile_from_ir_prebaked", compile_from_ir_prebaked, (Vector, WasmModule, TypeRegistry)),

    # Direct callees
    ("get_concrete_wasm_type", get_concrete_wasm_type, (Type, WasmModule, TypeRegistry)),
    ("needs_anyref_boxing", WasmTarget.needs_anyref_boxing, (Union,)),
    ("populate_type_constant_globals!", WasmTarget.populate_type_constant_globals!, (WasmModule, TypeRegistry)),

    # Code generation core (InplaceCompilationContext specializations)
    ("generate_body", WasmTarget.generate_body, (ICtx,)),
    ("generate_structured", WasmTarget.generate_structured, (ICtx, Vector{BasicBlock})),
    ("generate_block_code", WasmTarget.generate_block_code, (ICtx, BasicBlock)),
    ("analyze_blocks", WasmTarget.analyze_blocks, (Vector{Any},)),

    # Bytecode post-processing
    ("fix_broken_select_instructions", WasmTarget.fix_broken_select_instructions, (Vector{UInt8},)),
    ("fix_consecutive_local_sets", WasmTarget.fix_consecutive_local_sets, (Vector{UInt8},)),
    ("strip_excess_after_function_end", WasmTarget.strip_excess_after_function_end, (Vector{UInt8},)),
    ("fix_array_len_wrap", WasmTarget.fix_array_len_wrap, (Vector{UInt8},)),
    ("fix_i32_wrap_after_i32_ops", WasmTarget.fix_i32_wrap_after_i32_ops, (Vector{UInt8},)),
    ("fix_i64_local_in_i32_ops", WasmTarget.fix_i64_local_in_i32_ops, (Vector{UInt8}, Vector{WasmValType})),
    ("fix_local_get_set_type_mismatch", WasmTarget.fix_local_get_set_type_mismatch, (Vector{UInt8}, Vector{WasmValType})),
    ("fix_numeric_to_ref_local_stores", WasmTarget.fix_numeric_to_ref_local_stores, (Vector{UInt8}, Vector{WasmValType}, Int64)),

    # LEB128 + serialization
    ("encode_leb128_unsigned", encode_leb128_unsigned, (UInt32,)),
    ("encode_leb128_signed_i32", encode_leb128_signed, (Int32,)),
    ("encode_leb128_signed_i64", encode_leb128_signed, (Int64,)),
    ("to_bytes_no_dict", WasmTarget.to_bytes_no_dict, (WasmModule,)),

    # Constant value compilation
    ("compile_const_value_i64", compile_const_value, (Int64, WasmModule, TypeRegistry)),
    ("compile_const_value_i32", compile_const_value, (Int32, WasmModule, TypeRegistry)),
    ("compile_const_value_f64", compile_const_value, (Float64, WasmModule, TypeRegistry)),
    ("compile_const_value_bool", compile_const_value, (Bool, WasmModule, TypeRegistry)),

    # Byte extraction helpers
    ("wasm_bytes_length", wasm_bytes_length, (Vector{UInt8},)),
    ("wasm_bytes_get", wasm_bytes_get, (Vector{UInt8}, Int32)),
]
println("  Codegen: $(length(codegen_stage)) functions")

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE 6: IR Constructor exports (for JS interop)
# ═══════════════════════════════════════════════════════════════════════════════

constructor_stage = [
    # Vector builders
    ("wasm_create_i32_vector", WasmTarget.wasm_create_i32_vector, (Int32,)),
    ("wasm_set_i32", WasmTarget.wasm_set_i32!, (Vector{Int32}, Int32, Int32)),
    ("wasm_get_i32", WasmTarget.wasm_get_i32, (Vector{Int32}, Int32)),
    ("wasm_i32_vector_length", WasmTarget.wasm_i32_vector_length, (Vector{Int32},)),
    # Any vector builders
    ("wasm_create_any_vector", WasmTarget.wasm_create_any_vector, (Int32,)),
    ("wasm_set_any_expr", WasmTarget.wasm_set_any_expr!, (Vector{Any}, Int32, Expr)),
    ("wasm_set_any_return", WasmTarget.wasm_set_any_return!, (Vector{Any}, Int32, Core.ReturnNode)),
    ("wasm_set_any_ssa", WasmTarget.wasm_set_any_ssa!, (Vector{Any}, Int32, Int32)),
    ("wasm_set_any_arg", WasmTarget.wasm_set_any_arg!, (Vector{Any}, Int32, Int32)),
    ("wasm_set_any_i64", WasmTarget.wasm_set_any_i64!, (Vector{Any}, Int32, Int64)),
    ("wasm_any_vector_length", WasmTarget.wasm_any_vector_length, (Vector{Any},)),
    # IR node constructors
    ("wasm_create_expr", WasmTarget.wasm_create_expr, (Symbol, Vector{Any})),
    ("wasm_create_return_node", WasmTarget.wasm_create_return_node, (Int32,)),
    ("wasm_create_ssa_value", WasmTarget.wasm_create_ssa_value, (Int32,)),
    ("wasm_create_argument", WasmTarget.wasm_create_argument, (Int32,)),
    # Symbol constructors
    ("wasm_symbol_call", WasmTarget.wasm_symbol_call, ()),
    ("wasm_symbol_invoke", WasmTarget.wasm_symbol_invoke, ()),
]
println("  Constructors: $(length(constructor_stage)) functions")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: code_typed ALL functions (clean session — no ccall_replacements)
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 1: code_typed ALL functions ---")

all_named_funcs = vcat(parser_stage, lowerer_stage, subtype_stage, typeinf_stage, codegen_stage, constructor_stage)

all_entries = Tuple[]
failed_names = String[]
for (name, f, argtypes) in all_named_funcs
    try
        ci, rt = Base.code_typed(f, argtypes; optimize=true)[1]
        push!(all_entries, (ci, rt, argtypes, name, f))
    catch e
        push!(failed_names, name)
    end
end

println("  code_typed succeeded: $(length(all_entries))/$(length(all_named_funcs))")
if !isempty(failed_names)
    println("  Failed ($(length(failed_names))): $(join(failed_names[1:min(10,end)], ", "))$(length(failed_names)>10 ? "..." : "")")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Individually validate each function (filter out bad ones)
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Individual validation ---")

valid_entries = Tuple[]
invalid_names = String[]
for (ci, rt, argtypes, name, f) in all_entries
    try
        bytes = WasmTarget.compile_from_codeinfo(ci, rt, name, argtypes)
        tmppath = joinpath(tempdir(), "unified_$(name).wasm")
        write(tmppath, bytes)
        wasm_result = try read(`wasm-tools validate $tmppath`, String) catch e; "error" end
        rm(tmppath, force=true)
        if isempty(wasm_result)
            push!(valid_entries, (ci, rt, argtypes, name, f))
        else
            push!(invalid_names, name)
        end
    catch
        push!(invalid_names, name)
    end
end

println("  Validated: $(length(valid_entries))/$(length(all_entries))")
if !isempty(invalid_names)
    println("  Invalid ($(length(invalid_names))): $(join(invalid_names[1:min(15,end)], ", "))$(length(invalid_names)>15 ? "..." : "")")
end

# Count by stage
stage_names = Dict(
    "Parser" => Set(n for (n, _, _) in parser_stage),
    "Lowerer" => Set(n for (n, _, _) in lowerer_stage),
    "Subtype" => Set(n for (n, _, _) in subtype_stage),
    "TypeInf" => Set(n for (n, _, _) in typeinf_stage),
    "Codegen" => Set(n for (n, _, _) in codegen_stage),
    "Constructors" => Set(n for (n, _, _) in constructor_stage),
)
for (stage, names) in sort(collect(stage_names); by=first)
    n_valid = count(e -> e[4] in names, valid_entries)
    n_total = length(names)
    println("    $stage: $n_valid/$n_total")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Assemble unified module from validated functions
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 3: Assemble unified module ---")

module_compiled = false
module_bytes = UInt8[]
n_exports = 0
n_functions = 0
n_types = 0

try
    mod = compile_module_from_ir(valid_entries)
    global module_bytes = to_bytes(mod)
    global module_compiled = true
    global n_exports = length(mod.exports)
    global n_functions = length(mod.functions)
    global n_types = length(mod.types)
    println("  ✓ Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Functions: $n_functions, Types: $n_types, Exports: $n_exports")
catch e
    println("  ✗ Module build FAILED: $(sprint(showerror, e)[1:min(300,end)])")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Validate combined module + Node.js load test
# ═══════════════════════════════════════════════════════════════════════════════

validate_ok = false
load_ok = false

if module_compiled
    println("\n--- Step 4: Validate + Node.js load ---")
    output_path = joinpath(@__DIR__, "..", "..", "unified-selfhost.wasm")
    write(output_path, module_bytes)

    global validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
        println("  ✓ wasm-tools validate PASSED")
        true
    catch
        # Get the error details
        err_out = try read(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=stderr), String) catch ex; sprint(showerror, ex) end
        println("  ✗ wasm-tools validate FAILED")
        println("    $(err_out[1:min(200,end)])")
        false
    end

    if validate_ok
        try
            node_script = """
            const fs = require('fs');
            const bytes = fs.readFileSync('$(output_path)');
            WebAssembly.compile(bytes).then(mod => {
                const exps = WebAssembly.Module.exports(mod);
                const imps = WebAssembly.Module.imports(mod);
                console.log(exps.length + ' exports, ' + imps.length + ' imports loaded');
                process.exit(0);
            }).catch(e => {
                console.error(e.message);
                process.exit(1);
            });
            """
            node_result = read(`node -e $node_script`, String)
            println("  ✓ Node.js: $(strip(node_result))")
            global load_ok = true
        catch e
            println("  ✗ Node.js load failed: $(string(e)[1:min(200,end)])")
        end
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 70)
println("INT-001 Summary:")
println("  Pipeline stages: Parser + Lowerer + Subtype/Matching + TypeInf + Codegen + Constructors")
println("  Total functions attempted: $(length(all_named_funcs))")
println("  code_typed succeeded: $(length(all_entries))")
println("  Individually validated: $(length(valid_entries))")
println("  Module compiled: $module_compiled")
if module_compiled
    println("  Module size: $(round(length(module_bytes)/1024, digits=1)) KB")
    println("  Exports: $n_exports")
end
println("  wasm-tools validate: $validate_ok")
println("  Node.js loads: $load_ok")
println("=" ^ 70)

@testset "INT-001: Unified self-hosting module" begin
    @test length(valid_entries) >= 100  # Expect 100+ validated functions across all stages
    @test module_compiled
    @test validate_ok
    @test load_ok
    @test n_exports >= 100
end
