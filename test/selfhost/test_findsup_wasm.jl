# PHASE-2B-004: Implement findsup for invoke dispatch in WasmGC
#
# Run: julia +1.12 --project=. test/selfhost/test_findsup_wasm.jl
#
# wasm_findsup wraps wasm_matching_methods to find the most-specific method.

using Test
using WasmTarget
using Core.Compiler: MethodMatch, MethodLookupResult, WorldRange

include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "subtype.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "matching.jl"))

# Implement wasm_findsup
function wasm_findsup(@nospecialize(sig))
    result = _wasm_matching_methods_positional(sig, -1)
    result === nothing && return missing
    matches = result.matches
    isempty(matches) && return missing
    mm = matches[1]::MethodMatch
    return (mm, result.valid_worlds, result.ambig)
end

@testset "PHASE-2B-004: wasm_findsup → WasmGC" begin

    @testset "Native findsup correctness" begin
        # Test with known signatures
        r1 = wasm_findsup(Tuple{typeof(+), Int64, Int64})
        @test r1 !== missing
        @test r1[1] isa MethodMatch
        @test r1[1].method isa Method

        r2 = wasm_findsup(Tuple{typeof(*), Float64, Float64})
        @test r2 !== missing

        r3 = wasm_findsup(Tuple{typeof(abs), Int64})
        @test r3 !== missing

        # Non-existent method
        r4 = wasm_findsup(Tuple{typeof(sin), String})
        @test r4 === missing || (r4 !== missing && !r4[1].fully_covers)
    end

    @testset "wasm_findsup compiles to WasmGC" begin
        ci, rettype = Base.code_typed(wasm_findsup, (Any,))[1]
        bytes = WasmTarget.compile_from_codeinfo(ci, rettype, "wasm_findsup", (Any,))
        @test length(bytes) > 0
        @test length(ci.code) > 0
    end

    @testset "Combined findsup module validates" begin
        entries = [
            (wasm_findsup, (Any,)),
            (wasm_matching_methods, (Any,)),
            (_wasm_matching_methods_positional, (Any, Int)),
            (_get_all_methods, (Any,)),
            (_extract_sparams, (Any, Any)),
            (_extract_sparams_walk!, (Vector{Any}, Any, Any, SubtypeEnv)),
            (_in_interferences, (Method, Method)),
            (_method_morespecific, (Method, Method)),
            (_sort_by_specificity!, (Vector{Any},)),
            (_detect_ambiguity, (Vector{Any},)),
            (VarBinding, (TypeVar, Bool)),
            (SubtypeEnv, ()),
            (lookup, (SubtypeEnv, TypeVar)),
            (wasm_subtype, (Any, Any)),
            (_subtype, (Any, Any, SubtypeEnv, Int)),
            (wasm_type_intersection, (Any, Any)),
        ]

        bytes = compile_multi(entries)
        @test length(bytes) > 0

        path = joinpath(@__DIR__, "findsup_module.wasm")
        open(path, "w") do io; write(io, bytes); end

        @test success(run(ignorestatus(`wasm-tools validate $path`), wait=true))
        println("  Module: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB)")
    end

    @testset "Module loads in Node.js" begin
        path = joinpath(@__DIR__, "findsup_module.wasm")
        js = """
        const fs = require("fs");
        const bytes = fs.readFileSync("$path");
        const imports = { Math: { pow: Math.pow } };
        WebAssembly.instantiate(bytes, imports).then(r => {
            console.log("EXPORTS:" + Object.keys(r.instance.exports).length);
            console.log("HAS_FINDSUP:" + (typeof r.instance.exports.wasm_findsup === "function"));
        }).catch(e => console.error("ERROR:" + e.message));
        """
        js_path = "/tmp/test_findsup_load.cjs"
        open(js_path, "w") do io; write(io, js); end
        output = read(`node $js_path`, String)
        @test occursin("HAS_FINDSUP:true", output)
    end
end
