#!/usr/bin/env julia
# Debug: Dump WAT for _intersect_datatypes to understand Union{} return codegen
using WasmTarget
include(joinpath(@__DIR__, "..", "test", "utils.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "matching.jl"))

# First, look at the IR
println("=== IR for _intersect_datatypes ===")
ir = code_typed(_intersect_datatypes, (DataType, DataType, Int))[1]
ci = ir[1]
for (i, stmt) in enumerate(ci.code)
    typ = ci.ssavaluetypes[i]
    println("  %$i = $stmt :: $typ")
end
println("\nReturn type: ", ir[2])

# Now compile and dump WAT
test_isect2() = Int32(wasm_type_intersection(Int64, String) === Union{})

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
    [(test_isect2, ())])
bytes = compile_multi(funcs)
wasm_path = joinpath(@__DIR__, "debug_isect_dt.wasm")
write(wasm_path, bytes)
run(`wasm-tools validate --features=gc $wasm_path`)
println("VALIDATES")

# Find _intersect_datatypes function and dump its WAT
wat = read(`wasm-tools print $wasm_path`, String)

# Find the function index for _intersect_datatypes
m = match(r"\(export \"_intersect_datatypes\" \(func (\d+)\)\)", wat)
if m !== nothing
    func_idx = parse(Int, m.captures[1])
    println("\n=== _intersect_datatypes = func $func_idx ===")
    func_start = "(func (;$func_idx;)"
    start_pos = findfirst(func_start, wat)
    if start_pos !== nothing
        end_pos = findnext(r"\(func \(;\d+;\)", wat, start_pos[end])
        func_wat = if end_pos !== nothing
            wat[start_pos[1]:end_pos[1]-1]
        else
            wat[start_pos[1]:min(start_pos[1]+2000, length(wat))]
        end
        println(func_wat)
    end
end

# Also dump test_isect2 and wasm_type_intersection
for name in ["test_isect2", "wasm_type_intersection", "_intersect"]
    m2 = match(Regex("\\(export \"$name\" \\(func (\\d+)\\)\\)"), wat)
    if m2 !== nothing
        func_idx2 = parse(Int, m2.captures[1])
        println("\n=== $name = func $func_idx2 ===")
        func_start2 = "(func (;$func_idx2;)"
        start_pos2 = findfirst(func_start2, wat)
        if start_pos2 !== nothing
            end_pos2 = findnext(r"\(func \(;\d+;\)", wat, start_pos2[end])
            func_wat2 = if end_pos2 !== nothing
                wat[start_pos2[1]:end_pos2[1]-1]
            else
                wat[start_pos2[1]:min(start_pos2[1]+2000, length(wat))]
            end
            println(func_wat2)
        end
    end
end

# Run the test
r = run_wasm(bytes, "test_isect2")
println("\ntest_isect2 result: $r (expected: 1)")

# Clean up
rm(wasm_path, force=true)
