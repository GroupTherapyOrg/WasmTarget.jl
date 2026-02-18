#!/usr/bin/env julia
using WasmTarget
include(joinpath(@__DIR__, "..", "test", "utils.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "matching.jl"))

test_egal_globals() = Int32(Int64 === Int64)
test_egal_return() = begin
    x = wasm_type_intersection(Int64, Number)
    return Int32(x === Int64)
end
test_isect_1() = Int32(wasm_type_intersection(Int64, Number) === Int64)

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

funcs = vcat(
    subtype_functions,
    intersection_functions,
    matching_functions,
    [
        (test_egal_globals, ()),
        (test_egal_return, ()),
        (test_isect_1, ()),
    ],
)

bytes = compile_multi(funcs)
println("Compiled: $(length(bytes)) bytes")

wasm_path = joinpath(@__DIR__, "debug_egal.wasm")
write(wasm_path, bytes)
run(`wasm-tools validate --features=gc $wasm_path`)
println("VALIDATES")

# Dump WAT for test_egal_return and test_egal_globals
wat = read(`wasm-tools print $wasm_path`, String)
wat_path = joinpath(@__DIR__, "debug_egal.wat")
open(wat_path, "w") do io; print(io, wat); end
println("WAT written to $wat_path ($(length(wat)) chars)")

# Extract specific functions — find func indices
# func_31 = test_egal_globals, func_32 = test_egal_return, func_33 = test_isect_1
# Actually, let's find them by export name
for name in ["test_egal_globals", "test_egal_return", "test_isect_1"]
    println("\n--- Export: $name ---")
    # Find the export line  
    m = match(Regex("\\(export \"$name\" \\(func (\\d+)\\)\\)"), wat)
    if m !== nothing
        println("  func idx: $(m.captures[1])")
    end
end

# Run tests
for name in ["test_egal_globals", "test_egal_return", "test_isect_1"]
    print("$name → ")
    try
        r = run_wasm(bytes, name)
        println("$r")
    catch e
        println("ERROR: $(first(sprint(showerror, e), 80))")
    end
end
