#!/usr/bin/env julia
# PURE-4153: Compile typeinf.wasm with 25+ test wrappers for correctness gate
#
# Extends compile_typeinf_full.jl with additional test wrappers covering:
# - Subtype: 15 cases (concrete, abstract, identity, Union{}, negative)
# - Intersection: 8 cases (concrete, abstract, disjoint, identity)
# - Method matching: 5 cases (basic arithmetic, type queries)
# Total: 28 test wrappers

using WasmTarget

# Load all typeinf infrastructure
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))

using Core.Compiler: InferenceState

println("=" ^ 80)
println("PURE-4153: typeinf.wasm with 28 test wrappers")
println("=" ^ 80)

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

# ─── Compiler helper functions ───
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

# ─── Extended test wrappers (28 total) ───

# Subtype wrappers (15)
test_sub_1() = Int32(wasm_subtype(Int64, Number))       # true — concrete <: abstract
test_sub_2() = Int32(wasm_subtype(Int64, String))        # false — disjoint concrete
test_sub_3() = Int32(wasm_subtype(Float64, Real))        # true — concrete <: abstract
test_sub_4() = Int32(wasm_subtype(String, Any))          # true — anything <: Any
test_sub_5() = Int32(wasm_subtype(Any, Int64))           # false — Any not <: concrete
test_sub_6() = Int32(wasm_subtype(Bool, Integer))        # true — Bool <: Integer
test_sub_7() = Int32(wasm_subtype(UInt8, Signed))        # false — UInt8 not <: Signed
test_sub_8() = Int32(wasm_subtype(Int64, Int64))         # true — identity
test_sub_9() = Int32(wasm_subtype(Union{}, Int64))       # true — bottom <: anything
test_sub_10() = Int32(wasm_subtype(Int64, Union{}))      # false — concrete not <: bottom
test_sub_11() = Int32(wasm_subtype(Int32, Integer))      # true — Int32 <: Integer
test_sub_12() = Int32(wasm_subtype(Float32, AbstractFloat)) # true — Float32 <: AbstractFloat
test_sub_13() = Int32(wasm_subtype(Number, Any))         # true — abstract <: Any
test_sub_14() = Int32(wasm_subtype(Any, Any))            # true — Any <: Any (identity)
test_sub_15() = Int32(wasm_subtype(Union{}, Any))        # true — bottom <: Any

# Intersection wrappers (8)
test_isect_1() = Int32(wasm_type_intersection(Int64, Number) === Int64)        # true
test_isect_2() = Int32(wasm_type_intersection(Int64, String) === Union{})      # true — disjoint
test_isect_3() = Int32(wasm_type_intersection(Number, Real) === Real)          # true — subtype
test_isect_4() = Int32(wasm_type_intersection(Integer, Signed) === Signed)     # true
test_isect_5() = Int32(wasm_type_intersection(Any, Int64) === Int64)           # true — Any ∩ X = X
test_isect_6() = Int32(wasm_type_intersection(Int64, Int64) === Int64)         # true — identity
test_isect_7() = Int32(wasm_type_intersection(Float64, Integer) === Union{})   # true — disjoint
test_isect_8() = Int32(wasm_type_intersection(Real, AbstractFloat) === AbstractFloat) # true

# Method matching wrappers (5)
# wasm_matching_methods returns a Vector{Any} or nothing
# Test by checking length > 0 for known method signatures
test_match_1() = begin
    r = wasm_matching_methods(Tuple{typeof(+), Int64, Int64})
    Int32(r !== nothing && length(r) > 0 ? 1 : 0)
end
test_match_2() = begin
    r = wasm_matching_methods(Tuple{typeof(*), Float64, Float64})
    Int32(r !== nothing && length(r) > 0 ? 1 : 0)
end
test_match_3() = begin
    r = wasm_matching_methods(Tuple{typeof(-), Int64, Int64})
    Int32(r !== nothing && length(r) > 0 ? 1 : 0)
end
test_match_4() = begin
    r = wasm_matching_methods(Tuple{typeof(abs), Int64})
    Int32(r !== nothing && length(r) > 0 ? 1 : 0)
end
test_match_5() = begin
    r = wasm_matching_methods(Tuple{typeof(iseven), Int64})
    Int32(r !== nothing && length(r) > 0 ? 1 : 0)
end

# ─── Step 1: Verify native Julia ground truth ───
println("\n--- Step 1: Native Julia ground truth ---")

test_cases = [
    ("sub_1: Int64<:Number", test_sub_1, Int32(1)),
    ("sub_2: Int64<:String", test_sub_2, Int32(0)),
    ("sub_3: Float64<:Real", test_sub_3, Int32(1)),
    ("sub_4: String<:Any", test_sub_4, Int32(1)),
    ("sub_5: Any<:Int64", test_sub_5, Int32(0)),
    ("sub_6: Bool<:Integer", test_sub_6, Int32(1)),
    ("sub_7: UInt8<:Signed", test_sub_7, Int32(0)),
    ("sub_8: Int64<:Int64", test_sub_8, Int32(1)),
    ("sub_9: ⊥<:Int64", test_sub_9, Int32(1)),
    ("sub_10: Int64<:⊥", test_sub_10, Int32(0)),
    ("sub_11: Int32<:Integer", test_sub_11, Int32(1)),
    ("sub_12: Float32<:AbstractFloat", test_sub_12, Int32(1)),
    ("sub_13: Number<:Any", test_sub_13, Int32(1)),
    ("sub_14: Any<:Any", test_sub_14, Int32(1)),
    ("sub_15: ⊥<:Any", test_sub_15, Int32(1)),
    ("isect_1: Int64∩Number=Int64", test_isect_1, Int32(1)),
    ("isect_2: Int64∩String=⊥", test_isect_2, Int32(1)),
    ("isect_3: Number∩Real=Real", test_isect_3, Int32(1)),
    ("isect_4: Integer∩Signed=Signed", test_isect_4, Int32(1)),
    ("isect_5: Any∩Int64=Int64", test_isect_5, Int32(1)),
    ("isect_6: Int64∩Int64=Int64", test_isect_6, Int32(1)),
    ("isect_7: Float64∩Integer=⊥", test_isect_7, Int32(1)),
    ("isect_8: Real∩AbstractFloat=AF", test_isect_8, Int32(1)),
    ("match_1: +(Int64,Int64)", test_match_1, Int32(1)),
    ("match_2: *(Float64,Float64)", test_match_2, Int32(1)),
    ("match_3: -(Int64,Int64)", test_match_3, Int32(1)),
    ("match_4: abs(Int64)", test_match_4, Int32(1)),
    ("match_5: iseven(Int64)", test_match_5, Int32(1)),
]

for (label, f, expected) in test_cases
    native = f()
    status = native == expected ? "✓" : "✗ MISMATCH"
    println("  $label → native: $native (expected: $expected) $status")
    @assert native == expected "Ground truth mismatch for $label"
end
println("All $(length(test_cases)) ground truth cases verified ✓")

# ─── Step 2: Compile full module with all wrappers ───
println("\n--- Step 2: compile_multi ---")

wrapper_functions = [
    (test_sub_1, ()), (test_sub_2, ()), (test_sub_3, ()), (test_sub_4, ()), (test_sub_5, ()),
    (test_sub_6, ()), (test_sub_7, ()), (test_sub_8, ()), (test_sub_9, ()), (test_sub_10, ()),
    (test_sub_11, ()), (test_sub_12, ()), (test_sub_13, ()), (test_sub_14, ()), (test_sub_15, ()),
    (test_isect_1, ()), (test_isect_2, ()), (test_isect_3, ()), (test_isect_4, ()), (test_isect_5, ()),
    (test_isect_6, ()), (test_isect_7, ()), (test_isect_8, ()),
    (test_match_1, ()), (test_match_2, ()), (test_match_3, ()), (test_match_4, ()), (test_match_5, ()),
]

all_funcs = vcat(reimpl_functions, typeinf_entry, compiler_functions, wrapper_functions)
println("  Total explicit functions: $(length(all_funcs))")

bytes = nothing
try
    global bytes = compile_multi(all_funcs)
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
        println("  Aborting — must validate before Node.js testing")
        rm(tmpf, force=true)
        exit(1)
    end
    rm(tmpf, force=true)
catch e
    println("  COMPILE_ERROR: $(first(sprint(showerror, e), 400))")
    exit(1)
end

# Save module
outpath = joinpath(@__DIR__, "typeinf_4153.wasm")
write(outpath, bytes)
println("  Saved to scripts/typeinf_4153.wasm ($(length(bytes)) bytes)")

# ─── Step 3: Test in Node.js ───
println("\n--- Step 3: Node.js testing ---")

include(joinpath(@__DIR__, "..", "test", "utils.jl"))

if NODE_CMD === nothing
    println("  Node.js not available — VALIDATES only")
    exit(0)
end

results = []
for (label, f, expected) in test_cases
    func_name = string(nameof(f))
    print("  $label → ")
    try
        actual = run_wasm(bytes, func_name)
        if actual == expected
            println("Wasm: $actual — CORRECT ✓")
            push!(results, :pass)
        else
            println("Wasm: $actual — MISMATCH ✗ (expected $expected)")
            push!(results, :fail)
        end
    catch e
        errmsg = sprint(showerror, e)
        println("ERROR: $(first(errmsg, 80))")
        push!(results, :error)
    end
end

# ─── Results ───
println("\n" * "=" ^ 80)
total = length(test_cases)
pass_count = count(r -> r == :pass, results)
fail_count = count(r -> r == :fail, results)
error_count = count(r -> r == :error, results)
println("Results: $pass_count/$total CORRECT, $fail_count MISMATCH, $error_count ERROR")
if pass_count == total
    println("ALL CORRECT (level 3) ✓")
    println("PURE-4153 GATE: PASSED — M_TYPEINF_WASM COMPLETE")
else
    println("NOT all correct — $(total - pass_count) failures")
    println("PURE-4153 GATE: FAILED")
end
