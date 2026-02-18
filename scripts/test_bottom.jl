using WasmTarget
include(joinpath(@__DIR__, "..", "test", "utils.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "matching.jl"))

# Test if Union{} === Union{} works
test_bottom_egal() = Int32(Union{} === Union{})

# Test if the intersection returns the SAME Union{} object
# Using _subtype_check on Union{} instead of ===
test_isect2_via_subtype() = begin
    result = wasm_type_intersection(Int64, String)
    # Check if result is Union{} by checking: result <: Union{} (only Union{} <: Union{})
    return Int32(wasm_subtype(result, Union{}))
end

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

matching_functions = [(wasm_matching_methods, (Any,))]

funcs = vcat(subtype_functions, intersection_functions, matching_functions,
    [(test_bottom_egal, ()), (test_isect2_via_subtype, ())])
bytes = compile_multi(funcs)
println("Compiled: $(length(bytes)) bytes")
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
run(`wasm-tools validate --features=gc $tmpf`)
println("VALIDATES")
rm(tmpf, force=true)

r1 = run_wasm(bytes, "test_bottom_egal")
println("Union{} === Union{}: $r1 (expected 1)")
r2 = run_wasm(bytes, "test_isect2_via_subtype")
println("isect(Int64,String) <: Union{}: $r2 (expected 1)")
