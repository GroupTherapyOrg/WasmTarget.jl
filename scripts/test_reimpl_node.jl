#!/usr/bin/env julia
# PURE-4151: Test WasmGC reimplementations CORRECT in Node.js
#
# Strategy:
# 1. Define wrapper functions that call wasm_subtype/wasm_type_intersection
#    with hardcoded Type arguments and return Int32
# 2. compile_multi all reimplementation functions + wrappers into one module
# 3. Call each wrapper export in Node.js via run_wasm
# 4. Compare against native Julia ground truth → must be CORRECT (level 3)
#
# Type objects can't be passed from JS, so wrappers embed specific test cases.

using WasmTarget

# Load test harness (provides run_wasm, NODE_CMD, etc.)
include(joinpath(@__DIR__, "..", "test", "utils.jl"))

# Load reimplementation modules
include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "matching.jl"))

println("=" ^ 80)
println("PURE-4151: WasmGC reimplementations CORRECT in Node.js")
println("=" ^ 80)

# ─── Define wrapper test functions ───
# Each returns Int32(0) or Int32(1) for a specific hardcoded type pair.
# These get compiled alongside the reimplementation functions via compile_multi.

# Subtype wrappers
test_sub_1() = Int32(wasm_subtype(Int64, Number))       # true
test_sub_2() = Int32(wasm_subtype(Int64, String))        # false
test_sub_3() = Int32(wasm_subtype(Float64, Real))        # true
test_sub_4() = Int32(wasm_subtype(String, Any))          # true
test_sub_5() = Int32(wasm_subtype(Any, Int64))           # false
test_sub_6() = Int32(wasm_subtype(Bool, Integer))        # true
test_sub_7() = Int32(wasm_subtype(UInt8, Signed))        # false
test_sub_8() = Int32(wasm_subtype(Int64, Int64))         # true (identity)
test_sub_9() = Int32(wasm_subtype(Union{}, Int64))       # true (bottom)
test_sub_10() = Int32(wasm_subtype(Int64, Union{}))      # false

# Intersection wrappers (test result identity via ===)
test_isect_1() = Int32(wasm_type_intersection(Int64, Number) === Int64)        # true
test_isect_2() = Int32(wasm_type_intersection(Int64, String) === Union{})      # true
test_isect_3() = Int32(wasm_type_intersection(Number, Real) === Real)          # true
test_isect_4() = Int32(wasm_type_intersection(Integer, Signed) === Signed)     # true
test_isect_5() = Int32(wasm_type_intersection(Any, Int64) === Int64)           # true

# ─── Step 1: Native Julia ground truth ───
println("\n--- Step 1: Native Julia ground truth ---")

# Build test registry: (label, wrapper_func, expected_native)
test_cases = [
    # Subtype
    ("sub_1: Int64 <: Number",          test_sub_1,   Int32(1)),
    ("sub_2: Int64 <: String",          test_sub_2,   Int32(0)),
    ("sub_3: Float64 <: Real",          test_sub_3,   Int32(1)),
    ("sub_4: String <: Any",            test_sub_4,   Int32(1)),
    ("sub_5: Any <: Int64",             test_sub_5,   Int32(0)),
    ("sub_6: Bool <: Integer",          test_sub_6,   Int32(1)),
    ("sub_7: UInt8 <: Signed",          test_sub_7,   Int32(0)),
    ("sub_8: Int64 <: Int64",           test_sub_8,   Int32(1)),
    ("sub_9: Union{} <: Int64",         test_sub_9,   Int32(1)),
    ("sub_10: Int64 <: Union{}",        test_sub_10,  Int32(0)),
    # Intersection
    ("isect_1: Int64 ∩ Number = Int64", test_isect_1, Int32(1)),
    ("isect_2: Int64 ∩ String = ∅",     test_isect_2, Int32(1)),
    ("isect_3: Number ∩ Real = Real",   test_isect_3, Int32(1)),
    ("isect_4: Integer ∩ Signed",       test_isect_4, Int32(1)),
    ("isect_5: Any ∩ Int64 = Int64",    test_isect_5, Int32(1)),
]

# Verify ground truth
for (label, f, expected) in test_cases
    native = f()
    status = native == expected ? "✓" : "✗ MISMATCH"
    println("  $label → native: $native (expected: $expected) $status")
    @assert native == expected "Ground truth mismatch for $label"
end
println("All $(length(test_cases)) ground truth cases verified ✓")

# ─── Step 2: Compile all functions + wrappers ───
println("\n--- Step 2: compile_multi ---")

# All reimplementation functions (from compile_reimpl.jl)
subtype_functions = [
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
]

intersection_functions = [
    (wasm_type_intersection, (Any, Any)),
    (_no_free_typevars, (Any,)),
    (_intersect, (Any, Any, Int)),
    (_simple_join, (Any, Any)),
    (_intersect_datatypes, (DataType, DataType, Int)),
    (_intersect_tuple, (DataType, DataType, Int)),
    (_intersect_same_name, (DataType, DataType, Int)),
    (_intersect_invariant, (Any, Any)),
    (_intersect_different_names, (DataType, DataType, Int)),
]

matching_functions = [
    (wasm_matching_methods, (Any,)),
]

# Wrapper test functions (no-arg, return Int32)
wrapper_functions = [
    (test_sub_1, ()),
    (test_sub_2, ()),
    (test_sub_3, ()),
    (test_sub_4, ()),
    (test_sub_5, ()),
    (test_sub_6, ()),
    (test_sub_7, ()),
    (test_sub_8, ()),
    (test_sub_9, ()),
    (test_sub_10, ()),
    (test_isect_1, ()),
    (test_isect_2, ()),
    (test_isect_3, ()),
    (test_isect_4, ()),
    (test_isect_5, ()),
]

all_functions = vcat(subtype_functions, intersection_functions, matching_functions, wrapper_functions)

bytes = nothing
try
    global bytes = compile_multi(all_functions)
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
        println("  VALIDATE_ERROR: $(first(valerr, 200))")
        println("  Aborting — must validate before Node.js testing")
        exit(1)
    end
    rm(tmpf, force=true)
catch e
    println("  COMPILE_ERROR: $(sprint(showerror, e))")
    println("  Aborting — must compile before Node.js testing")
    exit(1)
end

# ─── Step 3: Test each wrapper in Node.js ───
println("\n--- Step 3: Node.js CORRECTNESS testing ---")

if NODE_CMD === nothing
    println("  Node.js not available — skipping execution tests")
    println("  VALIDATES only (level 1), cannot verify CORRECT (level 3)")
    exit(0)
end

pass_count = 0
fail_count = 0
error_count = 0

for (label, f, expected) in test_cases
    func_name = string(nameof(f))
    print("  $label → ")
    try
        actual = run_wasm(bytes, func_name)
        if actual == expected
            println("Wasm: $actual — CORRECT ✓")
            pass_count += 1
        else
            println("Wasm: $actual — MISMATCH ✗ (expected $expected)")
            fail_count += 1
        end
    catch e
        errmsg = sprint(showerror, e)
        println("ERROR: $(first(errmsg, 80))")
        error_count += 1
    end
end

# ─── Results ───
println("\n" * "=" ^ 80)
total = length(test_cases)
println("Results: $pass_count/$total CORRECT, $fail_count MISMATCH, $error_count ERROR")
if pass_count == total
    println("ALL CORRECT (level 3) ✓")
    println("PURE-4151 GATE: PASSED")
else
    println("NOT all correct — $(total - pass_count) failures")
    println("PURE-4151 GATE: FAILED")
end
