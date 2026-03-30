# PHASE-2B-002: Compile wasm_matching_methods (447 lines) to WasmGC
#
# Run: julia +1.12 --project=. test/selfhost/test_matching_wasm.jl
#
# Tests that all matching.jl functions compile, validate, and load.

using Test
using WasmTarget

include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "subtype.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "matching.jl"))

@testset "PHASE-2B-002: wasm_matching_methods → WasmGC" begin

    @testset "All matching functions compile individually" begin
        funcs = [
            ("_extract_sparams", _extract_sparams, (Any, Any)),
            ("_extract_sparams_walk!", _extract_sparams_walk!, (Vector{Any}, Any, Any, SubtypeEnv)),
            ("_get_all_methods", _get_all_methods, (Any,)),
            ("_in_interferences", _in_interferences, (Method, Method)),
            ("_method_morespecific", _method_morespecific, (Method, Method)),
            ("_sort_by_specificity!", _sort_by_specificity!, (Vector{Any},)),
            ("_detect_ambiguity", _detect_ambiguity, (Vector{Any},)),
            ("wasm_matching_methods", wasm_matching_methods, (Any,)),
            ("_wasm_matching_methods_positional", _wasm_matching_methods_positional, (Any, Int)),
        ]

        for (name, f, argtypes) in funcs
            ci, rettype = Base.code_typed(f, argtypes)[1]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            @test length(bytes) > 0
        end
        @test length(funcs) == 9
    end

    @testset "Combined subtype+matching module validates" begin
        entries = [
            # Core subtype (21)
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
            # Matching (9)
            (_extract_sparams, (Any, Any)),
            (_extract_sparams_walk!, (Vector{Any}, Any, Any, SubtypeEnv)),
            (_get_all_methods, (Any,)),
            (_in_interferences, (Method, Method)),
            (_method_morespecific, (Method, Method)),
            (_sort_by_specificity!, (Vector{Any},)),
            (_detect_ambiguity, (Vector{Any},)),
            (wasm_matching_methods, (Any,)),
            (_wasm_matching_methods_positional, (Any, Int)),
        ]

        bytes = compile_multi(entries)
        @test length(entries) == 30
        @test length(bytes) > 0

        path = joinpath(@__DIR__, "matching_module.wasm")
        open(path, "w") do io; write(io, bytes); end

        @test success(run(ignorestatus(`wasm-tools validate $path`), wait=true))
        println("  Module size: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB)")
        @test length(bytes) < 100_000
    end

    @testset "Module loads in Node.js" begin
        path = joinpath(@__DIR__, "matching_module.wasm")
        @test isfile(path)

        js = """
        const fs = require("fs");
        const bytes = fs.readFileSync("$path");
        const imports = { Math: { pow: Math.pow } };
        WebAssembly.instantiate(bytes, imports).then(r => {
            const n = Object.keys(r.instance.exports).length;
            console.log("EXPORTS:" + n);
            console.log("HAS_MATCHING:" + (typeof r.instance.exports.wasm_matching_methods === "function"));
        }).catch(e => console.error("ERROR:" + e.message));
        """
        js_path = "/tmp/test_matching_load.cjs"
        open(js_path, "w") do io; write(io, js); end
        output = read(`node $js_path`, String)

        @test occursin("EXPORTS:30", output)
        @test occursin("HAS_MATCHING:true", output)
    end
end
