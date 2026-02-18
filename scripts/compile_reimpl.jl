#!/usr/bin/env julia
# PURE-4150: Compile subtype/intersection/matching reimplementations to WasmGC
# Tests each function individually with compile(), then attempts compile_multi

using WasmTarget

include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "matching.jl"))

# Helper: try to compile, validate, return status
function try_compile_validate(f, argtypes; label="")
    local bytes
    try
        bytes = compile(f, argtypes)
    catch e
        return (status="COMPILE_ERROR", bytes=0, funcs=0, error=first(sprint(showerror, e), 120))
    end

    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = try
        parse(Int, readchomp(`bash -c "wasm-tools print $tmpf 2>/dev/null | grep -c '(func (;'"` ))
    catch
        0
    end

    try
        run(`wasm-tools validate --features=gc $tmpf`)
        return (status="VALIDATES", bytes=length(bytes), funcs=nfuncs, error="")
    catch
        valerr = try
            readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`)
        catch
            "unknown"
        end
        return (status="VALIDATE_ERROR", bytes=length(bytes), funcs=nfuncs, error=first(valerr, 120))
    finally
        rm(tmpf, force=true)
    end
end

println("=" ^ 80)
println("PURE-4150: Individual compilation of reimplemented functions")
println("=" ^ 80)

# ─── Phase 1: Individual function compilation ───
# Each function compiled standalone — stubs expected for helpers (they are in Main)
# This tests whether code_typed succeeds and basic codegen works

tests = [
    # Subtype core
    ("wasm_subtype", wasm_subtype, (Any, Any)),
    ("_subtype", _subtype, (Any, Any, SubtypeEnv, Int)),
    ("lookup", lookup, (SubtypeEnv, TypeVar)),
    ("VarBinding(2-arg)", VarBinding, (TypeVar, Bool)),
    ("_var_lt", _var_lt, (VarBinding, Any, SubtypeEnv, Int)),
    ("_var_gt", _var_gt, (VarBinding, Any, SubtypeEnv, Int)),
    ("_subtype_var", _subtype_var, (VarBinding, Any, SubtypeEnv, Bool, Int)),
    ("_record_var_occurrence", _record_var_occurrence, (VarBinding, SubtypeEnv, Int)),
    ("_subtype_unionall", _subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int)),
    ("_subtype_inner", _subtype_inner, (Any, Any, SubtypeEnv, Bool, Int)),
    ("_is_leaf_bound", _is_leaf_bound, (Any,)),
    ("_type_contains_var", _type_contains_var, (Any, TypeVar)),
    ("_subtype_check", _subtype_check, (Any, Any)),
    ("_subtype_datatypes", _subtype_datatypes, (DataType, DataType, SubtypeEnv, Int)),
    ("_forall_exists_equal", _forall_exists_equal, (Any, Any, SubtypeEnv)),
    ("_tuple_subtype_env", _tuple_subtype_env, (DataType, DataType, SubtypeEnv, Int)),
    ("_subtype_tuple_param", _subtype_tuple_param, (Any, Any, SubtypeEnv)),
    ("_datatype_subtype", _datatype_subtype, (DataType, DataType)),
    ("_tuple_subtype", _tuple_subtype, (DataType, DataType)),
    ("_subtype_param", _subtype_param, (Any, Any)),

    # Intersection
    ("wasm_type_intersection", wasm_type_intersection, (Any, Any)),
    ("_no_free_typevars", _no_free_typevars, (Any,)),
    ("_intersect", _intersect, (Any, Any, Int)),
    ("_simple_join", _simple_join, (Any, Any)),
    ("_intersect_datatypes", _intersect_datatypes, (DataType, DataType, Int)),
    ("_intersect_tuple", _intersect_tuple, (DataType, DataType, Int)),
    ("_intersect_same_name", _intersect_same_name, (DataType, DataType, Int)),
    ("_intersect_invariant", _intersect_invariant, (Any, Any)),
    ("_intersect_different_names", _intersect_different_names, (DataType, DataType, Int)),

    # Matching
    ("wasm_matching_methods", wasm_matching_methods, (Any,)),  # keyword arg limit has default
]

results = []
for (name, f, argtypes) in tests
    r = try_compile_validate(f, argtypes; label=name)
    push!(results, (name=name, r...))
    status_str = rpad(r.status, 16)
    println("  $(rpad(name, 30)) $status_str $(r.bytes)B $(r.funcs)f  $(r.error)")
end

println("\n" * "=" ^ 80)
validates = count(r -> r.status == "VALIDATES", results)
validate_err = count(r -> r.status == "VALIDATE_ERROR", results)
compile_err = count(r -> r.status == "COMPILE_ERROR", results)
println("VALIDATES: $validates / $(length(results))")
println("VALIDATE_ERROR: $validate_err")
println("COMPILE_ERROR: $compile_err")

# ─── Phase 2: Multi-function compilation ───
# Pass all subtype functions to compile_multi so they find each other
println("\n" * "=" ^ 80)
println("Phase 2: compile_multi with all subtype functions")
println("=" ^ 80)

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

try
    bytes = compile_multi(subtype_functions)
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
    end
    # Save for analysis
    write(joinpath(@__DIR__, "..", "scripts", "subtype_multi.wasm"), bytes)
    println("  Saved to scripts/subtype_multi.wasm")
    rm(tmpf, force=true)
catch e
    println("  COMPILE_ERROR: $(sprint(showerror, e))")
end

# ─── Phase 3: compile_multi with ALL functions (subtype + intersection + matching) ───
println("\n" * "=" ^ 80)
println("Phase 3: compile_multi with ALL functions")
println("=" ^ 80)

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

# For matching, the keyword arg version compiles to a non-keyword inner
matching_functions = [
    (wasm_matching_methods, (Any,)),
]

all_functions = vcat(subtype_functions, intersection_functions, matching_functions)

try
    bytes = compile_multi(all_functions)
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
    end
    write(joinpath(@__DIR__, "all_reimpl.wasm"), bytes)
    println("  Saved to scripts/all_reimpl.wasm")
    rm(tmpf, force=true)
catch e
    println("  COMPILE_ERROR: $(sprint(showerror, e))")
end

println("\nDone.")
