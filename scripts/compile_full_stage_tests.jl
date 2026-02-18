#!/usr/bin/env julia
# PURE-5001: Test ALL stages in the FULL pipeline module
#
# Previous tests found:
# - Stage 1 (parse): build_tree EXECUTES + CORRECT, parsestmt wrapper breaks
# - Stage 3 reimpl: 15/15 CORRECT (already in pipeline module)
# - Stages 2-4 need to be in the FULL module to have all dependencies
#
# This script adds test wrappers to the full pipeline compilation,
# then tests each in Node.js.

using WasmTarget
using JuliaSyntax
using JuliaLowering

# Load typeinf infrastructure
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
using Core.Compiler: InferenceState

include(joinpath(@__DIR__, "..", "test", "utils.jl"))

println("=" ^ 60)
println("PURE-5001: Full Pipeline Stage Execution Tests")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════
# Stage 1 test wrappers — use build_tree (parsestmt wrapper broken)
# ═══════════════════════════════════════════════════════════════

# Test: parse "1+1" → Expr(:call, :+, 1, 1)
function test_parse_1plus1()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Expr ? Int32(1) : Int32(0)
end

# Test: parse "42" → 42 (Int64)
function test_parse_42()::Int32
    ps = JuliaSyntax.ParseStream("42")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result isa Int64 ? Int32(1) : Int32(0)
end

# ═══════════════════════════════════════════════════════════════
# Stage 3 test wrappers — reimpl (already confirmed)
# ═══════════════════════════════════════════════════════════════

# These are just sanity checks — already 15/15 CORRECT
test_sub_sanity() = Int32(wasm_subtype(Int64, Number))
test_isect_sanity() = Int32(wasm_type_intersection(Int64, Number) === Int64)

# ═══════════════════════════════════════════════════════════════
# Stage 4 test wrappers — compile (self-hosting)
# ═══════════════════════════════════════════════════════════════

# Note: compile calls Base.code_typed() which runs NATIVE Julia's compiler.
# For true self-hosting, this would need to be replaced with the
# compiled-to-WasmGC typeinf. But for now, compile() in WasmGC
# will try to call code_typed which is a ccall/intrinsic — likely traps.

# Test: compile simple function → produces bytes?
function test_compile_identity()::Int32
    f(x::Int64)::Int64 = x
    bytes = WasmTarget.compile(f, Tuple{Int64})
    return length(bytes) > 0 ? Int32(1) : Int32(0)
end

# ═══════════════════════════════════════════════════════════════
# Include all original pipeline functions for dependencies
# ═══════════════════════════════════════════════════════════════

parse_expr_string(s::String) = JuliaSyntax.parsestmt(Expr, s)
const CT = JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol,Any}}}

# All stage functions (from compile_pipeline.jl)
stage1_functions = [(parse_expr_string, (String,))]
stage2_functions = [(JuliaLowering._to_lowered_expr, (CT, Int64))]

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

typeinf_entry = [(Core.Compiler.typeinf, (WasmInterpreter, InferenceState))]

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
stage4_functions = [(WasmTarget.compile, (Function, Type{Tuple{Int64}}))]

# Simple pipeline test wrappers (known-good)
pipeline_add(a::Int64, b::Int64)::Int64 = a + b

# Test wrappers
test_wrappers = [
    (test_parse_1plus1, ()),
    (test_parse_42, ()),
    (test_sub_sanity, ()),
    (test_isect_sanity, ()),
    (test_compile_identity, ()),
    (pipeline_add, (Int64, Int64)),
]

# Compile ALL into one module
all_functions = vcat(
    stage1_functions,
    stage2_functions,
    stage3_functions,
    stage4_functions,
    test_wrappers,
)

println("\nCompiling full pipeline + test wrappers...")
bytes = try
    b = compile_multi(all_functions)
    println("  compile_multi SUCCESS: $(length(b)) bytes")
    b
catch e
    println("  COMPILE_ERROR: $(first(sprint(showerror, e), 300))")
    exit(1)
end

# Validate
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
try
    run(`wasm-tools validate --features=gc $tmpf`)
    println("  VALIDATES ✓")
catch
    valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
    println("  VALIDATE_ERROR: $(first(valerr, 200))")
end

# Save
outpath = joinpath(@__DIR__, "full_stage_tests.wasm")
write(outpath, bytes)
println("  SAVED: scripts/full_stage_tests.wasm ($(length(bytes)) bytes)")

# Node.js tests
if NODE_CMD !== nothing
    println("\n--- Node.js Stage Execution Tests ---")

    test_cases = [
        ("test_parse_1plus1 (Stage 1: parse '1+1' → Expr)", "test_parse_1plus1", Int32(1)),
        ("test_parse_42 (Stage 1: parse '42' → Int64)", "test_parse_42", Int32(1)),
        ("test_sub_sanity (Stage 3: Int64<:Number)", "test_sub_sanity", Int32(1)),
        ("test_isect_sanity (Stage 3: Int64∩Number=Int64)", "test_isect_sanity", Int32(1)),
        ("test_compile_identity (Stage 4: compile identity)", "test_compile_identity", Int32(1)),
    ]

    for (label, fname, expected) in test_cases
        print("  $label → ")
        try
            actual = run_wasm(bytes, fname)
            if actual == expected
                println("EXECUTES + CORRECT ✓")
            else
                println("EXECUTES but WRONG (got $actual, expected $expected)")
            end
        catch e
            emsg = sprint(showerror, e)
            if contains(emsg, "unreachable")
                println("TRAP")
            elseif contains(emsg, "timeout")
                println("HANG/TIMEOUT")
            else
                println("ERROR: $(first(emsg, 100))")
            end
        end
    end

    # Also test pipeline_add to confirm module is OK
    print("  pipeline_add(3,4)=7 (sanity check) → ")
    try
        actual = run_wasm(bytes, "pipeline_add", Int64(3), Int64(4))
        println(actual == Int64(7) ? "CORRECT ✓" : "WRONG ($actual)")
    catch e
        println("ERROR: $(first(sprint(showerror, e), 100))")
    end
end

rm(tmpf, force=true)
println("\nDone.")
