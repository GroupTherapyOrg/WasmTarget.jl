using WasmTarget
include(joinpath(@__DIR__, "..", "test", "utils.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "matching.jl"))

test_isect_2() = Int32(wasm_type_intersection(Int64, String) === Union{})

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

funcs = vcat(subtype_functions, intersection_functions, matching_functions, [(test_isect_2, ())])
bytes = compile_multi(funcs)
wasm_path = joinpath(@__DIR__, "debug_isect2.wasm")
write(wasm_path, bytes)
run(`wasm-tools validate --features=gc $wasm_path`)
println("VALIDATES")

# Dump WAT and find test_isect_2
wat = read(`wasm-tools print $wasm_path`, String)
m = match(r"\(export \"test_isect_2\" \(func (\d+)\)\)", wat)
if m !== nothing
    func_idx = parse(Int, m.captures[1])
    println("test_isect_2 = func $func_idx")
    # Extract the function WAT
    func_start = "(func (;$func_idx;)"
    start_pos = findfirst(func_start, wat)
    if start_pos !== nothing
        end_pos = findnext("(func (;$(func_idx+1);)", wat, start_pos[end])
        if end_pos !== nothing
            println(wat[start_pos[1]:end_pos[1]-1])
        else
            println(wat[start_pos[1]:min(start_pos[1]+500, length(wat))])
        end
    end
end

r = run_wasm(bytes, "test_isect_2")
println("Result: $r (expected: 1)")
