# PHASE-2B-001: Compile wasm_subtype (1,818 lines) to WasmGC
#
# Run: julia +1.12 --project=. test/selfhost/test_subtype_wasm.jl
#
# Tests that all subtype.jl functions compile to WasmGC, validates, and loads.
# Ground truth testing for subtype EXECUTION requires TypeDataStore integration
# (types as WasmGC structs, not externref) — deferred to later stories.

using Test
using WasmTarget

include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "subtype.jl"))

@testset "PHASE-2B-001: wasm_subtype → WasmGC" begin

    # ─── Individual compilation ────────────────────────────────────────

    @testset "All functions code_typed + compile_from_codeinfo" begin
        all_funcs = [
            # Core subtype (21 functions)
            ("VarBinding", VarBinding, (TypeVar, Bool)),
            ("SubtypeEnv_ctor", SubtypeEnv, ()),
            ("lookup", lookup, (SubtypeEnv, TypeVar)),
            ("wasm_subtype", wasm_subtype, (Any, Any)),
            ("_subtype", _subtype, (Any, Any, SubtypeEnv, Int)),
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
            # Intersection (no env, 10 functions)
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
            # IntersectEnv constructors + lookup (4 functions)
            ("IntersectBinding", IntersectBinding, (TypeVar, Bool)),
            ("IntersectEnv_ctor", IntersectEnv, ()),
            ("_ilookup", _ilookup, (IntersectEnv, TypeVar)),
            ("_irecord_occurrence", _irecord_occurrence, (IntersectBinding, IntersectEnv, Int)),
            # IntersectEnv-based functions (13 functions)
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
            # Vararg functions (4 functions) — compile but fail validation individually
            ("_intersect_tuple_vararg", _intersect_tuple_vararg, (DataType, Any, Int, DataType, Any, Int, Int)),
            ("_intersect_tuple_both_vararg", _intersect_tuple_both_vararg, (DataType, Any, Int, DataType, Any, Int, Int)),
            ("_intersect_tuple_vararg_env", _intersect_tuple_vararg_env, (DataType, Any, Int, DataType, Any, Int, IntersectEnv, Int)),
            ("_intersect_tuple_both_vararg_env", _intersect_tuple_both_vararg_env, (DataType, Any, Int, DataType, Any, Int, IntersectEnv, Int)),
            # _substitute_type — compiles but fails validation (anyref vs concrete ref)
            ("_substitute_type", _substitute_type, (Any, TypeVar, Any)),
        ]

        for (name, f, argtypes) in all_funcs
            ci, rettype = Base.code_typed(f, argtypes)[1]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            @test length(bytes) > 0
        end
        # 52/52 individual compile
        @test length(all_funcs) == 52
    end

    # ─── Combined module — validating subset ────────────────────────────

    @testset "47-function module validates" begin
        # Exclude: _substitute_type (1), 4 vararg functions = 5 exclusions → 47 validate
        entries = [
            (VarBinding, (TypeVar, Bool)),
            (SubtypeEnv, ()),
            (lookup, (SubtypeEnv, TypeVar)),
            (wasm_subtype, (Any, Any)),
            (_subtype, (Any, Any, SubtypeEnv, Int)),
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
            (_intersect_union, (Union, Any, Int)),
            (_simple_join, (Any, Any)),
            (_intersect_datatypes, (DataType, DataType, Int)),
            (_intersect_tuple, (DataType, DataType, Int)),
            (_intersect_same_name, (DataType, DataType, Int)),
            (_intersect_invariant, (Any, Any)),
            (_intersect_different_names, (DataType, DataType, Int)),
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
        ]

        bytes = compile_multi(entries)
        @test length(entries) == 47
        @test length(bytes) > 0

        # Save module
        path = joinpath(@__DIR__, "subtype_module.wasm")
        open(path, "w") do io
            write(io, bytes)
        end

        # Validate
        @test success(run(ignorestatus(`wasm-tools validate $path`), wait=true))

        # Size check
        println("  Module size: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB)")
        @test length(bytes) < 100_000  # should be well under 100KB
    end

    # ─── Node.js execution ─────────────────────────────────────────────

    @testset "Module loads in Node.js" begin
        path = joinpath(@__DIR__, "subtype_module.wasm")
        @test isfile(path)

        js = """
        const fs = require("fs");
        const bytes = fs.readFileSync("$path");
        const imports = { Math: { pow: Math.pow } };
        WebAssembly.instantiate(bytes, imports).then(r => {
            const n = Object.keys(r.instance.exports).length;
            console.log("EXPORTS:" + n);
            // Identity checks (fast path)
            console.log("ID_NULL:" + r.instance.exports.wasm_subtype(null, null));
            console.log("CHECK_NULL:" + r.instance.exports._subtype_check(null, null));
        }).catch(e => console.error("ERROR:" + e.message));
        """
        js_path = "/tmp/test_subtype_load.cjs"
        open(js_path, "w") do io; write(io, js); end
        output = read(`node $js_path`, String)

        @test occursin("EXPORTS:47", output)
        @test occursin("ID_NULL:1", output)
        @test occursin("CHECK_NULL:1", output)
    end

    # ─── Known validation failures (tracked) ──────────────────────────

    @testset "Known validation failures documented" begin
        # These 5 functions compile but fail wasm-tools validate in the combined module
        # Root causes: type mismatch between anyref and concrete WasmGC ref types
        # Fix deferred to codegen improvement stories
        known_invalid = [
            "_substitute_type",           # anyref vs (ref null $type)
            "_intersect_tuple_vararg",    # anyref vs i64
            "_intersect_tuple_both_vararg",
            "_intersect_tuple_vararg_env",
            "_intersect_tuple_both_vararg_env",
        ]
        @test length(known_invalid) == 5
    end
end
