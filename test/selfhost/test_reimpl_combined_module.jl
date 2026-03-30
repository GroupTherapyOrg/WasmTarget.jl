# test_reimpl_combined_module.jl — PHASE-2B-007: Reassemble self-hosted-compiler.wasm
#
# Combines Phase 2a typeinf + Phase 2b subtype/matching/intersection/findsup
# into a single validated WasmGC module.
#
# Run: julia +1.12 --project=. test/selfhost/test_reimpl_combined_module.jl

using Test
using WasmTarget
using Core.Compiler: InferenceResult, InferenceState, MethodMatch,
                     MethodLookupResult, WorldRange

include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "ccall_stubs.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "subtype.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "matching.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "ccall_replacements.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "dict_method_table.jl"))

# ─── Setup types (no populate_method_table — avoids reimpl cycle) ─────────

world = Base.get_world_counter()
dict_table = DictMethodTable(world)
interp = WasmInterpreter(world, dict_table)
interp_type = typeof(interp)

mi_pair = Base.code_typed(+, (Int64, Int64))[1]
mi = mi_pair[1].parent
src = Core.Compiler.retrieve_code_info(mi, world)
result = InferenceResult(mi)
frame = InferenceState(result, src, :no, interp)

function wasm_findsup(@nospecialize(sig))
    result = _wasm_matching_methods_positional(sig, -1)
    result === nothing && return missing
    matches = result.matches
    isempty(matches) && return missing
    mm = matches[1]::MethodMatch
    return (mm, result.valid_worlds, result.ambig)
end

# ─── Collect functions ────────────────────────────────────────────────────

println("=== PHASE-2B-007: Reassemble self-hosted-compiler.wasm ===\n")

# Phase 2a: code_typed with optimize=false → compile_module_from_ir format
p2a_targets = [
    # Group A: WasmInterpreter interface
    (Core.Compiler.method_table,        (interp_type,),   "method_table"),
    (Core.Compiler.InferenceParams,     (interp_type,),   "InferenceParams"),
    (Core.Compiler.OptimizationParams,  (interp_type,),   "OptimizationParams"),
    (Core.Compiler.get_inference_world,  (interp_type,),   "get_inference_world"),
    (Core.Compiler.get_inference_cache,  (interp_type,),   "get_inference_cache"),
    # Group B: Core typeinf
    (Core.Compiler.specialize_method, (Core.MethodMatch,), "specialize_method"),
    (Core.Compiler.typeinf,          (interp_type, typeof(frame)), "typeinf"),
    (Core.Compiler.findall, (Type, typeof(interp.method_table.table)), "findall_DictMethodTable"),
    (Core.Compiler.isoverlayed, (typeof(interp.method_table.table),), "isoverlayed"),
    # Group C: CodeInfo construction
    (get_code_info, (typeof(PreDecompressedCodeInfo()), Core.MethodInstance), "get_code_info"),
    (InferenceResult, (Core.MethodInstance,), "InferenceResult_ctor"),
    (Core.Compiler.retrieve_code_info, (Core.MethodInstance, UInt64), "retrieve_code_info"),
    (InferenceState, (typeof(result), typeof(src), Symbol, interp_type), "InferenceState_ctor"),
]

# Phase 2b: subtype + matching + intersection + findsup
# Using exact signatures proven in PHASE-2B-001 through 004.
# Excluding 5 deferred (vararg + _substitute_type) that have anyref validation issues.
p2b_targets = [
    # Core subtype (21 functions)
    (VarBinding, (TypeVar, Bool), "VarBinding"),
    (SubtypeEnv, (), "SubtypeEnv_ctor"),
    (lookup, (SubtypeEnv, TypeVar), "lookup"),
    (wasm_subtype, (Any, Any), "wasm_subtype"),
    (_subtype, (Any, Any, SubtypeEnv, Int), "_subtype"),
    (_var_lt, (VarBinding, Any, SubtypeEnv, Int), "_var_lt"),
    (_var_gt, (VarBinding, Any, SubtypeEnv, Int), "_var_gt"),
    (_subtype_var, (VarBinding, Any, SubtypeEnv, Bool, Int), "_subtype_var"),
    (_record_var_occurrence, (VarBinding, SubtypeEnv, Int), "_record_var_occurrence"),
    (_subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int), "_subtype_unionall"),
    (_subtype_inner, (Any, Any, SubtypeEnv, Bool, Int), "_subtype_inner"),
    (_is_leaf_bound, (Any,), "_is_leaf_bound"),
    (_type_contains_var, (Any, TypeVar), "_type_contains_var"),
    (_subtype_check, (Any, Any), "_subtype_check"),
    (_subtype_datatypes, (DataType, DataType, SubtypeEnv, Int), "_subtype_datatypes"),
    (_forall_exists_equal, (Any, Any, SubtypeEnv), "_forall_exists_equal"),
    (_tuple_subtype_env, (DataType, DataType, SubtypeEnv, Int), "_tuple_subtype_env"),
    (_subtype_tuple_param, (Any, Any, SubtypeEnv), "_subtype_tuple_param"),
    (_datatype_subtype, (DataType, DataType), "_datatype_subtype"),
    (_tuple_subtype, (DataType, DataType), "_tuple_subtype"),
    (_subtype_param, (Any, Any), "_subtype_param"),
    # Simple intersection (10 functions)
    (wasm_type_intersection, (Any, Any), "wasm_type_intersection"),
    (_no_free_typevars, (Any,), "_no_free_typevars"),
    (_intersect, (Any, Any, Int), "_intersect"),
    (_intersect_union, (Union, Any, Int), "_intersect_union"),
    (_simple_join, (Any, Any), "_simple_join"),
    (_intersect_datatypes, (DataType, DataType, Int), "_intersect_datatypes"),
    (_intersect_tuple, (DataType, DataType, Int), "_intersect_tuple"),
    (_intersect_same_name, (DataType, DataType, Int), "_intersect_same_name"),
    (_intersect_invariant, (Any, Any), "_intersect_invariant"),
    (_intersect_different_names, (DataType, DataType, Int), "_intersect_different_names"),
    # IntersectEnv-based (16 functions)
    (IntersectBinding, (TypeVar, Bool), "IntersectBinding"),
    (IntersectEnv, (), "IntersectEnv_ctor"),
    (_ilookup, (IntersectEnv, TypeVar), "_ilookup"),
    (_irecord_occurrence, (IntersectBinding, IntersectEnv, Int), "_irecord_occurrence"),
    (_intersect_env, (Any, Any, IntersectEnv, Int), "_intersect_env"),
    (_intersect_union_env, (Union, Any, IntersectEnv, Int), "_intersect_union_env"),
    (_intersect_ivar, (TypeVar, IntersectBinding, Any, IntersectEnv, Int), "_intersect_ivar"),
    (_intersect_aside, (Any, Any, IntersectEnv), "_intersect_aside"),
    (_intersect_unionall_inner, (Any, UnionAll, IntersectEnv, Bool, Int), "_intersect_unionall_inner"),
    (_finish_unionall, (Any, IntersectBinding, UnionAll), "_finish_unionall"),
    (_no_free_typevars_val, (Any,), "_no_free_typevars_val"),
    (_intersect_datatypes_env, (DataType, DataType, IntersectEnv, Int), "_intersect_datatypes_env"),
    (_intersect_tuple_env, (DataType, DataType, IntersectEnv, Int), "_intersect_tuple_env"),
    (_intersect_same_name_env, (DataType, DataType, IntersectEnv, Int), "_intersect_same_name_env"),
    (_intersect_invariant_env, (Any, Any, IntersectEnv), "_intersect_invariant_env"),
    (_intersect_different_names_env, (DataType, DataType, IntersectEnv, Int), "_intersect_different_names_env"),
    # Matching (9 functions)
    (wasm_matching_methods, (Any,), "wasm_matching_methods"),
    (_wasm_matching_methods_positional, (Any, Int), "_wasm_matching_methods_positional"),
    (_get_all_methods, (Any,), "_get_all_methods"),
    (_extract_sparams, (Any, Any), "_extract_sparams"),
    (_extract_sparams_walk!, (Vector{Any}, Any, Any, SubtypeEnv), "_extract_sparams_walk!"),
    (_in_interferences, (Method, Method), "_in_interferences"),
    (_method_morespecific, (Method, Method), "_method_morespecific"),
    (_sort_by_specificity!, (Vector{Any},), "_sort_by_specificity!"),
    (_detect_ambiguity, (Vector{Any},), "_detect_ambiguity"),
    # Findsup (1 function)
    (wasm_findsup, (Any,), "wasm_findsup"),
]

# ─── Compile all functions ────────────────────────────────────────────────

all_entries = []  # (CodeInfo, rettype, argtypes, name) format
p2a_ok = 0
p2a_fail = 0

println("--- Compiling Phase 2a functions ---")
for (f, atypes, name) in p2a_targets
    try
        ci_pair = only(Base.code_typed(f, atypes; optimize=false))
        push!(all_entries, (ci_pair[1], ci_pair[2], atypes, name))
        global p2a_ok += 1
    catch e
        global p2a_fail += 1
        println("  ✗ $name — $(sprint(showerror, e)[1:min(80,end)])")
    end
end
println("  P2a: $p2a_ok/$(length(p2a_targets))")
p2b_ok = 0
p2b_fail = 0
println("\n--- Compiling Phase 2b functions ---")
for (f, atypes, name) in p2b_targets
    try
        ci_pair = only(Base.code_typed(f, atypes; optimize=false))
        push!(all_entries, (ci_pair[1], ci_pair[2], atypes, name))
        global p2b_ok += 1
    catch e
        global p2b_fail += 1
        println("  ✗ $name — $(sprint(showerror, e)[1:min(80,end)])")
    end
end
println("  P2b: $p2b_ok/$(length(p2b_targets))")
total_compiled = p2a_ok + p2b_ok
total_fail = p2a_fail + p2b_fail
println("  Total: $total_compiled functions ($total_fail failed)")

# ─── Assemble module ──────────────────────────────────────────────────────

println("\n--- Assembling combined module ---")

module_bytes = UInt8[]
module_compiled = false
n_exports = 0

try
    mod = WasmTarget.compile_module_from_ir(all_entries)
    global module_bytes = WasmTarget.to_bytes(mod)
    global n_exports = length(mod.exports)
    global module_compiled = true
    raw_kb = round(length(module_bytes)/1024, digits=1)
    println("  ✓ Module: $(length(module_bytes)) bytes ($raw_kb KB)")
    println("    Functions: $(length(mod.functions)), Types: $(length(mod.types)), Exports: $n_exports")
catch e
    println("  ✗ Assembly failed: $(sprint(showerror, e)[1:min(500,end)])")
end

# ─── Validate ─────────────────────────────────────────────────────────────

validate_ok = false
load_ok = false

if module_compiled
    output_path = joinpath(@__DIR__, "..", "..", "self-hosted-compiler-reimpl.wasm")
    write(output_path, module_bytes)

    println("\n--- Validation ---")
    global validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
        true
    catch
        false
    end
    println("  wasm-tools validate: $(validate_ok ? "PASS" : "FAIL")")

    # Node.js load
    js_code = "const fs=require('fs');const b=fs.readFileSync('$output_path');WebAssembly.compile(b).then(m=>{const e=WebAssembly.Module.exports(m);console.log('OK:'+e.length+' exports')}).catch(e=>{console.error('FAIL:'+e.message);process.exit(1)})"
    tmpjs = tempname() * ".cjs"
    write(tmpjs, js_code)
    load_output = try strip(read(`node $tmpjs`, String)) catch e; "ERROR: $e" end
    global load_ok = startswith(load_output, "OK")
    println("  Node.js: $load_output")

    # Size
    raw_kb = round(length(module_bytes)/1024, digits=1)
    est_brotli = round(length(module_bytes) * 0.35 / 1024, digits=1)
    println("\n--- Size ---")
    println("  Raw: $raw_kb KB, Est. Brotli: ~$est_brotli KB")
    println("  P2a was 22.2 KB, delta: +$(round(raw_kb - 22.2, digits=1)) KB")
end

# ─── Tests ────────────────────────────────────────────────────────────────

@testset "PHASE-2B-007: Combined reimpl module" begin
    @test total_compiled >= 50
    @test module_compiled
    @test length(module_bytes) > 0
    @test n_exports >= 40
    if module_compiled
        @test validate_ok
        @test load_ok
        @test length(module_bytes) < 5_000_000
        @test length(module_bytes) > 30_000
    end
end

println("\n=== PHASE-2B-007: Test complete ===")
