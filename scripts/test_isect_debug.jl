#!/usr/bin/env julia
# Debug: Why does wasm_type_intersection(Int64, Number) === Int64 return false?
using WasmTarget
include(joinpath(@__DIR__, "..", "test", "utils.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "matching.jl"))

if NODE_CMD === nothing
    println("Node.js not available — aborting")
    exit(1)
end

# ─── Test 1: Does wasm_type_intersection return the right thing? ───
println("=" ^ 60)
println("Test 1: What does wasm_type_intersection return?")
println("  Native: wasm_type_intersection(Int64, Number) = $(wasm_type_intersection(Int64, Number))")
println("  Native: wasm_type_intersection(Int64, Number) === Int64 = $(wasm_type_intersection(Int64, Number) === Int64)")

# ─── Test 2: _datatype_subtype identity test (simple, no === needed) ───
println("\n" * "=" ^ 60)
println("Test 2: _datatype_subtype(Int64, Number) — simple subtype test")

test_dsub() = Int32(_datatype_subtype(Int64, Number))

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

# ─── Test 3: Isolate the === issue ───
# Compare result of intersection with a hardcoded global
println("\n" * "=" ^ 60)
println("Test 3: Isolation — does === work for function return vs global?")

# A: Just return the intersection result as-is (externref)
# Can't do this easily, but we can test identity differently:

# B: Test _subtype_check which uses ===:
# _subtype_check(a, b) checks if a <: b AND b <: a, using ===
test_subcheck() = Int32(_subtype_check(Int64, Number))  # false (not symmetric)
test_subcheck2() = Int32(_subtype_check(Int64, Int64))  # true (identity)

# C: Test if returned DataType globals match by calling _datatype_subtype on the result
# Instead of `result === Int64`, check `_datatype_subtype(result, Int64) && _datatype_subtype(Int64, result)`
test_isect_via_subtype() = begin
    result = wasm_type_intersection(Int64, Number)
    if result isa DataType
        return Int32(_datatype_subtype(result, Int64) && _datatype_subtype(Int64, result))
    end
    return Int32(0)
end

# D: Test simple === between two globals (no function call return)
test_egal_globals() = Int32(Int64 === Int64)
test_egal_globals2() = Int32(Int64 === Number)

# E: Test === between function return and global
test_egal_return() = begin
    x = wasm_type_intersection(Int64, Number)
    return Int32(x === Int64)
end

funcs = vcat(
    subtype_functions,
    intersection_functions,
    matching_functions,
    [
        (test_dsub, ()),
        (test_subcheck, ()),
        (test_subcheck2, ()),
        (test_isect_via_subtype, ()),
        (test_egal_globals, ()),
        (test_egal_globals2, ()),
        (test_egal_return, ()),
    ],
)

bytes = compile_multi(funcs)
println("  Compiled: $(length(bytes)) bytes")

tmpf = tempname() * ".wasm"
write(tmpf, bytes)
try
    run(`wasm-tools validate --features=gc $tmpf`)
    println("  VALIDATES ✓")
catch
    valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
    println("  VALIDATE_ERROR: $(first(valerr, 200))")
    rm(tmpf, force=true)
    exit(1)
end
rm(tmpf, force=true)

# Run tests
tests = [
    ("test_dsub", 1, "datatype_subtype(Int64, Number)"),
    ("test_subcheck", 0, "subtype_check(Int64, Number) — not symmetric"),
    ("test_subcheck2", 1, "subtype_check(Int64, Int64) — identity"),
    ("test_egal_globals", 1, "Int64 === Int64 — global vs global"),
    ("test_egal_globals2", 0, "Int64 === Number — different globals"),
    ("test_egal_return", 1, "wasm_type_intersection(Int64,Number) === Int64"),
    ("test_isect_via_subtype", 1, "intersection result checked via subtype"),
]

for (fname, expected, desc) in tests
    print("  $desc → ")
    try
        r = run_wasm(bytes, fname)
        status = r == expected ? "CORRECT ✓" : "MISMATCH ✗ (got $r, expected $expected)"
        println(status)
    catch e
        println("ERROR: $(first(sprint(showerror, e), 80))")
    end
end

println("\nDone.")
