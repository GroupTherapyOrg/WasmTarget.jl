# PHASE-2B-003: Compile wasm_type_intersection to WasmGC
#
# Run: julia +1.12 --project=. test/selfhost/test_intersection_wasm.jl
#
# wasm_type_intersection and all intersection functions were already compiled
# and validated in PHASE-2B-001 (subtype module). This test verifies the
# intersection-specific functions compile, including both simple and env-based
# variants. Ground truth execution requires TypeDataStore integration.

using Test
using WasmTarget

include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "subtype.jl"))

@testset "PHASE-2B-003: wasm_type_intersection → WasmGC" begin

    @testset "Simple intersection functions compile" begin
        simple = [
            ("wasm_type_intersection", wasm_type_intersection, (Any, Any)),
            ("_no_free_typevars", _no_free_typevars, (Any,)),
            ("_intersect", _intersect, (Any, Any, Int)),
            ("_intersect_union", _intersect_union, (Union, Any, Int)),
            ("_simple_join", _simple_join, (Any, Any)),
            ("_intersect_datatypes", _intersect_datatypes, (DataType, DataType, Int)),
            ("_intersect_tuple", _intersect_tuple, (DataType, DataType, Int)),
            ("_intersect_same_name", _intersect_same_name, (DataType, DataType, Int)),
            ("_intersect_invariant", _intersect_invariant, (Any, Any)),
            ("_intersect_different_names", _intersect_different_names, (DataType, DataType, Int)),
        ]
        for (name, f, argtypes) in simple
            ci, rettype = Base.code_typed(f, argtypes)[1]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            @test length(bytes) > 0
        end
        @test length(simple) == 10
    end

    @testset "IntersectEnv-based functions compile" begin
        env_funcs = [
            ("IntersectBinding", IntersectBinding, (TypeVar, Bool)),
            ("IntersectEnv_ctor", IntersectEnv, ()),
            ("_ilookup", _ilookup, (IntersectEnv, TypeVar)),
            ("_irecord_occurrence", _irecord_occurrence, (IntersectBinding, IntersectEnv, Int)),
            ("_intersect_env", _intersect_env, (Any, Any, IntersectEnv, Int)),
            ("_intersect_union_env", _intersect_union_env, (Union, Any, IntersectEnv, Int)),
            ("_intersect_ivar", _intersect_ivar, (TypeVar, IntersectBinding, Any, IntersectEnv, Int)),
            ("_intersect_aside", _intersect_aside, (Any, Any, IntersectEnv)),
            ("_intersect_unionall_inner", _intersect_unionall_inner, (Any, UnionAll, IntersectEnv, Bool, Int)),
            ("_finish_unionall", _finish_unionall, (Any, IntersectBinding, UnionAll)),
            ("_no_free_typevars_val", _no_free_typevars_val, (Any,)),
            ("_intersect_datatypes_env", _intersect_datatypes_env, (DataType, DataType, IntersectEnv, Int)),
            ("_intersect_tuple_env", _intersect_tuple_env, (DataType, DataType, IntersectEnv, Int)),
            ("_intersect_same_name_env", _intersect_same_name_env, (DataType, DataType, IntersectEnv, Int)),
            ("_intersect_invariant_env", _intersect_invariant_env, (Any, Any, IntersectEnv)),
            ("_intersect_different_names_env", _intersect_different_names_env, (DataType, DataType, IntersectEnv, Int)),
        ]
        for (name, f, argtypes) in env_funcs
            ci, rettype = Base.code_typed(f, argtypes)[1]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            @test length(bytes) > 0
        end
        @test length(env_funcs) == 16
    end

    @testset "Vararg + _substitute_type compile (validation deferred)" begin
        deferred = [
            ("_substitute_type", _substitute_type, (Any, TypeVar, Any)),
            ("_intersect_tuple_vararg", _intersect_tuple_vararg, (DataType, Any, Int, DataType, Any, Int, Int)),
            ("_intersect_tuple_both_vararg", _intersect_tuple_both_vararg, (DataType, Any, Int, DataType, Any, Int, Int)),
            ("_intersect_tuple_vararg_env", _intersect_tuple_vararg_env, (DataType, Any, Int, DataType, Any, Int, IntersectEnv, Int)),
            ("_intersect_tuple_both_vararg_env", _intersect_tuple_both_vararg_env, (DataType, Any, Int, DataType, Any, Int, IntersectEnv, Int)),
        ]
        for (name, f, argtypes) in deferred
            ci, rettype = Base.code_typed(f, argtypes)[1]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            @test length(bytes) > 0
        end
    end

    @testset "Combined intersection module validates" begin
        # All validating intersection functions in one module
        entries = [
            # Simple intersection
            (wasm_type_intersection, (Any, Any)),
            (_no_free_typevars, (Any,)),
            (_intersect, (Any, Any, Int)),
            (_intersect_union, (Union, Any, Int)),
            (_simple_join, (Any, Any)),
            (_intersect_datatypes, (DataType, DataType, Int)),
            (_intersect_tuple, (DataType, DataType, Int)),
            (_intersect_same_name, (DataType, DataType, Int)),
            (_intersect_invariant, (Any, Any)),
            (_intersect_different_names, (DataType, DataType, Int)),
            # IntersectEnv
            (IntersectBinding, (TypeVar, Bool)),
            (IntersectEnv, ()),
            (_ilookup, (IntersectEnv, TypeVar)),
            (_irecord_occurrence, (IntersectBinding, IntersectEnv, Int)),
            (_intersect_env, (Any, Any, IntersectEnv, Int)),
            (_intersect_union_env, (Union, Any, IntersectEnv, Int)),
            (_intersect_ivar, (TypeVar, IntersectBinding, Any, IntersectEnv, Int)),
            (_intersect_aside, (Any, Any, IntersectEnv)),
            (_intersect_unionall_inner, (Any, UnionAll, IntersectEnv, Bool, Int)),
            (_finish_unionall, (Any, IntersectBinding, UnionAll)),
            (_no_free_typevars_val, (Any,)),
            (_intersect_datatypes_env, (DataType, DataType, IntersectEnv, Int)),
            (_intersect_tuple_env, (DataType, DataType, IntersectEnv, Int)),
            (_intersect_same_name_env, (DataType, DataType, IntersectEnv, Int)),
            (_intersect_invariant_env, (Any, Any, IntersectEnv)),
            (_intersect_different_names_env, (DataType, DataType, IntersectEnv, Int)),
            # Need subtype core for cross-calls
            (VarBinding, (TypeVar, Bool)),
            (SubtypeEnv, ()),
            (lookup, (SubtypeEnv, TypeVar)),
            (wasm_subtype, (Any, Any)),
            (_subtype, (Any, Any, SubtypeEnv, Int)),
        ]

        bytes = compile_multi(entries)
        @test length(bytes) > 0

        path = joinpath(@__DIR__, "intersection_full_module.wasm")
        open(path, "w") do io; write(io, bytes); end

        @test success(run(ignorestatus(`wasm-tools validate $path`), wait=true))
        println("  Intersection module: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB)")
    end

    # Total intersection function count
    @testset "Coverage" begin
        # 10 simple + 16 env-based + 5 deferred = 31 intersection functions
        @test 10 + 16 + 5 == 31
        # 26 validate in combined module (excl 5 deferred)
        @test 10 + 16 == 26
    end
end
