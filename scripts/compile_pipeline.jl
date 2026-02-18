#!/usr/bin/env julia
# PURE-4160: Compile full 4-stage pipeline into ONE WasmGC module
#
# Stages:
# 1. parsestmt (JuliaSyntax) — string → Expr
# 2. lowering (JuliaLowering) — SyntaxTree → lowered IR
# 3. typeinf (Core.Compiler + Julia reimplementations) — typed CodeInfo
# 4. codegen (WasmTarget self-hosting) — compile → .wasm bytes
#
# Goal: All 4 stages compile into ONE module that VALIDATES.
# The module includes entry points from each stage plus the type system
# reimplementations (subtype, intersection, matching).

using WasmTarget
using JuliaSyntax
using JuliaLowering

# Load typeinf reimplementation infrastructure
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))

using Core.Compiler: InferenceState

println("=" ^ 80)
println("PURE-4160: Full 4-stage pipeline — ONE WasmGC module")
println("=" ^ 80)

# Helper: compile, validate, report
function compile_and_report(label, func_list)
    println("\n--- $label ---")
    println("  Total explicit functions: $(length(func_list))")
    local bytes
    try
        bytes = compile_multi(func_list)
    catch e
        println("  COMPILE_ERROR: $(first(sprint(showerror, e), 400))")
        return nothing
    end
    println("  compile_multi SUCCESS: $(length(bytes)) bytes")
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = try
        out = read(pipeline(`wasm-tools print $tmpf`, `grep -c "(func "`), String)
        parse(Int, strip(out))
    catch; -1 end
    nexports = try
        out = read(pipeline(`wasm-tools print $tmpf`, `grep -c "(export "`), String)
        parse(Int, strip(out))
    catch; -1 end
    println("  Wasm functions: $nfuncs, exports: $nexports")
    try
        run(`wasm-tools validate --features=gc $tmpf`)
        println("  VALIDATES ✓")
    catch
        valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
        println("  VALIDATE_ERROR: $(first(valerr, 400))")
    end
    rm(tmpf, force=true)
    return bytes
end

# ═══════════════════════════════════════════════════════════════════════════
# STAGE 1: JuliaSyntax.parsestmt — string → Expr
# ═══════════════════════════════════════════════════════════════════════════
parse_expr_string(s::String) = JuliaSyntax.parsestmt(Expr, s)

stage1_functions = [
    (parse_expr_string, (String,)),
]

# ═══════════════════════════════════════════════════════════════════════════
# STAGE 2: JuliaLowering — SyntaxTree → lowered IR
# ═══════════════════════════════════════════════════════════════════════════
const CT = JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol,Any}}}

stage2_functions = [
    (JuliaLowering._to_lowered_expr, (CT, Int64)),
]

# ═══════════════════════════════════════════════════════════════════════════
# STAGE 3: Core.Compiler.typeinf + Julia reimplementations
# ═══════════════════════════════════════════════════════════════════════════

# All reimplementation functions
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

# Core.Compiler.typeinf entry point
typeinf_entry = [
    (Core.Compiler.typeinf, (WasmInterpreter, InferenceState)),
]

# Compiler helper functions
const CC = Core.Compiler
compiler_functions = Tuple{Any, Tuple}[]
push!(compiler_functions, (CC._unioncomplexity, (Any,)))
push!(compiler_functions, (CC.widenconst, (Any,)))
push!(compiler_functions, (CC._typename, (Any,)))
push!(compiler_functions, (CC.instanceof_tfunc, (Any,)))
push!(compiler_functions, (CC.is_same_frame, (CC.AbstractInterpreter, Core.MethodInstance, CC.InferenceState)))
push!(compiler_functions, (CC.add_edges!, (Vector{Any}, CC.CallInfo)))
push!(compiler_functions, (CC.merge_call_chain!, (CC.AbstractInterpreter, CC.InferenceState, CC.InferenceState)))
push!(compiler_functions, (CC.resolve_call_cycle!, (CC.AbstractInterpreter, Core.MethodInstance, CC.InferenceState)))
push!(compiler_functions, (CC.decode_effects, (UInt32,)))
push!(compiler_functions, (CC.tname_intersect, (Core.TypeName, Core.TypeName)))
push!(compiler_functions, (CC.type_more_complex, (Any, Any, Core.SimpleVector, Int, Int, Int)))
push!(compiler_functions, (CC.count_const_size, (Any, Bool)))
push!(compiler_functions, (CC.code_cache, (CC.AbstractInterpreter,)))
push!(compiler_functions, (CC.adjust_effects, (CC.InferenceState,)))
push!(compiler_functions, (Base._uniontypes, (Any, Vector{Any})))
push!(compiler_functions, (Base.unionlen, (Any,)))
push!(compiler_functions, (Base.datatype_fieldcount, (DataType,)))
push!(compiler_functions, (CC.widenwrappedslotwrapper, (Any,)))
push!(compiler_functions, (CC.argtypes_to_type, (Vector{Any},)))
push!(compiler_functions, (CC.collect_const_args, (Vector{Any}, Int)))

stage3_functions = vcat(reimpl_functions, typeinf_entry, compiler_functions)

# ═══════════════════════════════════════════════════════════════════════════
# STAGE 4: WasmTarget.compile — self-hosting codegen
# ═══════════════════════════════════════════════════════════════════════════
stage4_functions = [
    (WasmTarget.compile, (Function, Type{Tuple{Int64}})),
]

# ═══════════════════════════════════════════════════════════════════════════
# Test wrappers: verify each stage works in the combined module
# ═══════════════════════════════════════════════════════════════════════════

# Stage verification: simple arithmetic (proves module loads + executes)
test_add_1_1() = Int32(1 + 1)

# Stage 3 verification: type system reimplementation
test_sub_1() = Int32(wasm_subtype(Int64, Number))       # true
test_sub_2() = Int32(wasm_subtype(Int64, String))        # false
test_isect_1() = Int32(wasm_type_intersection(Int64, Number) === Int64)  # true
test_isect_2() = Int32(wasm_type_intersection(Int64, String) === Union{})  # true (disjoint)

test_wrappers = [
    (test_add_1_1, ()),
    (test_sub_1, ()),
    (test_sub_2, ()),
    (test_isect_1, ()),
    (test_isect_2, ()),
]

# ═══════════════════════════════════════════════════════════════════════════
# INCREMENTAL BUILD: Add stages one at a time
# ═══════════════════════════════════════════════════════════════════════════

# Phase 1: Stage 1 only (parsestmt)
println("\n" * "=" ^ 60)
bytes1 = compile_and_report("Phase 1: Stage 1 — parsestmt", stage1_functions)

# Phase 2: Stage 1 + Stage 2 (parsestmt + lowering)
println("\n" * "=" ^ 60)
phase2 = vcat(stage1_functions, stage2_functions)
bytes2 = compile_and_report("Phase 2: Stages 1+2 — parse + lower", phase2)

# Phase 3: Stage 1 + Stage 2 + Stage 3 (+ typeinf reimpl)
println("\n" * "=" ^ 60)
phase3 = vcat(stage1_functions, stage2_functions, stage3_functions)
bytes3 = compile_and_report("Phase 3: Stages 1+2+3 — parse + lower + typeinf", phase3)

# Phase 4: ALL stages (+ self-hosting codegen)
println("\n" * "=" ^ 60)
phase4 = vcat(stage1_functions, stage2_functions, stage3_functions, stage4_functions)
bytes4 = compile_and_report("Phase 4: ALL 4 stages — full pipeline", phase4)

# Phase 5: Full pipeline + test wrappers
println("\n" * "=" ^ 60)
phase5 = vcat(stage1_functions, stage2_functions, stage3_functions, stage4_functions, test_wrappers)
bytes5 = compile_and_report("Phase 5: Full pipeline + test wrappers", phase5)

# ═══════════════════════════════════════════════════════════════════════════
# SAVE BEST MODULE
# ═══════════════════════════════════════════════════════════════════════════
# Pick best phase (prefer most complete)
best = if bytes5 !== nothing
    bytes5
elseif bytes4 !== nothing
    bytes4
elseif bytes3 !== nothing
    bytes3
elseif bytes2 !== nothing
    bytes2
elseif bytes1 !== nothing
    bytes1
else
    nothing
end

best_label = if best === bytes5
    "Phase 5: full + tests"
elseif best === bytes4
    "Phase 4: all 4 stages"
elseif best === bytes3
    "Phase 3: stages 1-3"
elseif best === bytes2
    "Phase 2: stages 1-2"
elseif best === bytes1
    "Phase 1: stage 1 only"
else
    ""
end

if best !== nothing
    outpath = joinpath(@__DIR__, "pipeline.wasm")
    write(outpath, best)
    println("\n" * "=" ^ 80)
    println("SAVED: $best_label → scripts/pipeline.wasm ($(length(best)) bytes)")
    println("=" ^ 80)
else
    println("\n" * "=" ^ 80)
    println("ALL PHASES FAILED — no module saved")
    println("=" ^ 80)
    exit(1)
end

# ═══════════════════════════════════════════════════════════════════════════
# NODE.JS QUICK TEST (if available)
# ═══════════════════════════════════════════════════════════════════════════
if best !== nothing
    include(joinpath(@__DIR__, "..", "test", "utils.jl"))
    if NODE_CMD !== nothing
        println("\n--- Node.js verification ---")
        test_cases = [
            ("test_add_1_1: 1+1=2", "test_add_1_1", Int32(2)),
            ("test_sub_1: Int64<:Number", "test_sub_1", Int32(1)),
            ("test_sub_2: Int64≮:String", "test_sub_2", Int32(0)),
            ("test_isect_1: Int64∩Number=Int64", "test_isect_1", Int32(1)),
            ("test_isect_2: Int64∩String=⊥", "test_isect_2", Int32(1)),
        ]
        local pass_count = 0
        local total_count = length(test_cases)
        for (label, fname, expected) in test_cases
            print("  $label → ")
            try
                actual = run_wasm(best, fname)
                if actual == expected
                    println("CORRECT ✓")
                    pass_count += 1
                else
                    println("MISMATCH ✗ (got $actual, expected $expected)")
                end
            catch e
                println("ERROR: $(first(sprint(showerror, e), 80))")
            end
        end
        println("\nResults: $pass_count/$total_count CORRECT")
        if pass_count == total_count
            println("ALL CORRECT (level 3) ✓")
        end
    else
        println("\n--- Node.js not available — VALIDATES only ---")
    end
end

println("\nDone.")
