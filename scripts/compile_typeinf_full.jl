#!/usr/bin/env julia
# PURE-4152: Compile full typeinf.wasm — Core.Compiler.typeinf + Julia reimplementations
#
# Strategy:
# 1. Load all typeinf infrastructure (stubs, reimpl, DictMethodTable, WasmInterpreter)
# 2. Phase 1: Compile typeinf alone (baseline)
# 3. Phase 2: compile_multi with reimpl functions + typeinf (31 explicit)
# 4. Phase 3: Add key Compiler functions from COMPILES_NOW classification
# 5. Validate each phase with wasm-tools

using WasmTarget

# Load all typeinf infrastructure
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))

using Core.Compiler: InferenceState

println("=" ^ 80)
println("PURE-4152: Full typeinf.wasm compilation")
println("=" ^ 80)

# Helper: compile, validate, report
function compile_and_report(label, func_list)
    println("\n--- $label ---")
    println("  Total explicit functions: $(length(func_list))")
    local bytes
    try
        bytes = compile_multi(func_list)
    catch e
        println("  COMPILE_ERROR: $(first(sprint(showerror, e), 300))")
        return nothing
    end
    println("  compile_multi SUCCESS: $(length(bytes)) bytes")
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = try
        parse(Int, readchomp(`bash -c "wasm-tools print $tmpf 2>/dev/null | grep -c '(func (;'"` ))
    catch; 0 end
    println("  Functions: $nfuncs")
    try
        run(`wasm-tools validate --features=gc $tmpf`)
        println("  VALIDATES ✓")
    catch
        valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
        println("  VALIDATE_ERROR: $(first(valerr, 300))")
    end
    rm(tmpf, force=true)
    return bytes
end

# ─── All reimplementation functions ───
reimpl_functions = [
    (wasm_subtype, (Any, Any)),
    (_subtype, (Any, Any, SubtypeEnv, Int)),
    (lookup, (SubtypeEnv, TypeVar)),
    (VarBinding, (TypeVar, Bool)),
    (_var_lt, (VarBinding, Any, SubtypeEnv, Int)),
    (_var_gt, (VarBinding, Any, SubtypeEnv, Int)),
    (_subtype_var, (VarBinding, Any, SubtypeEnv, Bool, Int)),
    (_record_var_occurrence, (VarBinding, SubtypeEnv, Int)),
    (_subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int)),
    (_subtype_inner, (Any, Any, SubtypeEnv, Bool, Int)),
    (_is_leaf_bound, (Any,)),
    (_type_contains_var, (Any, TypeVar)),
    (_subtype_check, (Any, Any)),
    (_subtype_datatypes, (DataType, DataType, SubtypeEnv, Int)),
    (_forall_exists_equal, (Any, Any, SubtypeEnv)),
    (_tuple_subtype_env, (DataType, DataType, SubtypeEnv, Int)),
    (_subtype_tuple_param, (Any, Any, SubtypeEnv)),
    (_datatype_subtype, (DataType, DataType)),
    (_tuple_subtype, (DataType, DataType)),
    (_subtype_param, (Any, Any)),
    (wasm_type_intersection, (Any, Any)),
    (_no_free_typevars, (Any,)),
    (_intersect, (Any, Any, Int)),
    (_simple_join, (Any, Any)),
    (_intersect_datatypes, (DataType, DataType, Int)),
    (_intersect_tuple, (DataType, DataType, Int)),
    (_intersect_same_name, (DataType, DataType, Int)),
    (_intersect_invariant, (Any, Any)),
    (_intersect_different_names, (DataType, DataType, Int)),
    (wasm_matching_methods, (Any,)),
]

# ─── Core.Compiler.typeinf entry point ───
typeinf_entry = [
    (Core.Compiler.typeinf, (WasmInterpreter, InferenceState)),
]

# ─── Phase 2: Reimpl + typeinf ───
phase2_funcs = vcat(reimpl_functions, typeinf_entry)
bytes2 = compile_and_report("Phase 2: reimpl + typeinf (31 funcs)", phase2_funcs)

# ─── Phase 3: Add key Core.Compiler functions ───
# These are the COMPILES_NOW functions from PURE-3001 classification
# that the typeinf module depends on.
const CC = Core.Compiler
compiler_functions = Tuple{Any, Tuple}[]

# Type system operations (key for typeinf)
push!(compiler_functions, (CC._unioncomplexity, (Any,)))
push!(compiler_functions, (CC.widenconst, (Any,)))
push!(compiler_functions, (CC._typename, (Any,)))
push!(compiler_functions, (CC.instanceof_tfunc, (Any,)))

# Inference state management
push!(compiler_functions, (CC.is_same_frame, (CC.AbstractInterpreter, Core.MethodInstance, CC.InferenceState)))
push!(compiler_functions, (CC.add_edges!, (Vector{Any}, CC.CallInfo)))
push!(compiler_functions, (CC.merge_call_chain!, (CC.AbstractInterpreter, CC.InferenceState, CC.InferenceState)))
push!(compiler_functions, (CC.resolve_call_cycle!, (CC.AbstractInterpreter, Core.MethodInstance, CC.InferenceState)))
# Removed: compute_edges! — fails validation (struct_get on SimpleVector array type)
# push!(compiler_functions, (CC.compute_edges!, (CC.InferenceState,)))

# Type lattice and effects
push!(compiler_functions, (CC.decode_effects, (UInt32,)))
push!(compiler_functions, (CC.tname_intersect, (Core.TypeName, Core.TypeName)))
push!(compiler_functions, (CC.type_more_complex, (Any, Any, Core.SimpleVector, Int, Int, Int)))
push!(compiler_functions, (CC.count_const_size, (Any, Bool)))

# Codegen/optimization (disabled but compiled)
push!(compiler_functions, (CC.code_cache, (CC.AbstractInterpreter,)))

# Abstract evaluation — some have validation errors in multi-func context, add selectively
# push!(compiler_functions, (CC.abstract_eval_special_value, ...))  # func 45 VALIDATE_ERROR
# push!(compiler_functions, (CC.abstract_eval_value, ...))
# push!(compiler_functions, (CC.collect_argtypes, ...))
# push!(compiler_functions, (CC.abstract_eval_globalref, ...))
# push!(compiler_functions, (CC.abstract_eval_copyast, ...))
# push!(compiler_functions, (CC.abstract_eval_isdefined_expr, ...))

# Adjust effects
push!(compiler_functions, (CC.adjust_effects, (CC.InferenceState,)))  # 1-arg variant

# Base functions used by typeinf
push!(compiler_functions, (Base._uniontypes, (Any, Vector{Any})))
push!(compiler_functions, (Base.unionlen, (Any,)))
push!(compiler_functions, (Base.datatype_fieldcount, (DataType,)))

# Type lattice
push!(compiler_functions, (CC.widenwrappedslotwrapper, (Any,)))
push!(compiler_functions, (CC.argtypes_to_type, (Vector{Any},)))
push!(compiler_functions, (CC.collect_const_args, (Vector{Any}, Int)))

# Build combined list
phase3_funcs = vcat(reimpl_functions, typeinf_entry, compiler_functions)
bytes3 = compile_and_report("Phase 3: reimpl + typeinf + Compiler functions ($(length(phase3_funcs)) funcs)", phase3_funcs)

# ─── Phase 4: Test wrapper functions for PURE-4153 ───
# These call wasm_subtype/wasm_type_intersection with hardcoded types
# and return Int32 for easy Node.js comparison
test_sub_1() = Int32(wasm_subtype(Int64, Number))
test_sub_2() = Int32(wasm_subtype(Int64, String))
test_sub_3() = Int32(wasm_subtype(Float64, Real))
test_sub_4() = Int32(wasm_subtype(String, Any))
test_sub_5() = Int32(wasm_subtype(Any, Int64))
test_isect_1() = Int32(wasm_type_intersection(Int64, Number) === Int64)
test_isect_2() = Int32(wasm_type_intersection(Int64, String) === Union{})
test_isect_3() = Int32(wasm_type_intersection(Number, Real) === Real)

wrapper_functions = [
    (test_sub_1, ()),
    (test_sub_2, ()),
    (test_sub_3, ()),
    (test_sub_4, ()),
    (test_sub_5, ()),
    (test_isect_1, ()),
    (test_isect_2, ()),
    (test_isect_3, ()),
]

phase4_funcs = vcat(phase3_funcs, wrapper_functions)
bytes4 = compile_and_report("Phase 4: FULL module + test wrappers ($(length(phase4_funcs)) funcs)", phase4_funcs)

# ─── Save final module ───
if bytes4 !== nothing
    outpath = joinpath(@__DIR__, "typeinf_full.wasm")
    write(outpath, bytes4)
    println("\n  FINAL: Saved to scripts/typeinf_full.wasm ($(length(bytes4)) bytes)")
elseif bytes3 !== nothing
    outpath = joinpath(@__DIR__, "typeinf_full.wasm")
    write(outpath, bytes3)
    println("\n  FINAL: Saved Phase 3 to scripts/typeinf_full.wasm ($(length(bytes3)) bytes)")
elseif bytes2 !== nothing
    outpath = joinpath(@__DIR__, "typeinf_full.wasm")
    write(outpath, bytes2)
    println("\n  FINAL: Saved Phase 2 to scripts/typeinf_full.wasm ($(length(bytes2)) bytes)")
end

println("\nDone.")
