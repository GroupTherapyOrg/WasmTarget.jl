# test_intersection_cache.jl — Test intersection cache WasmGC emission
#
# PHASE-2A-010: Compile type intersection cache to WasmGC.
# Decision: Pre-compute intersections at build time (Option 1 for Phase 2a).
#
# Run: julia +1.12 --project=. test/selfhost/test_intersection_cache.jl

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "dict_method_table.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "typeid_registry.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "method_table_emit.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "minimal_method.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "type_data_store.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "intersection_cache.jl"))

# ─── Build test data with transitive populate (to get real intersections) ─────

test_sigs = [
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(-), Float64, Float64},
    Tuple{typeof(length), Vector{Int64}},
    Tuple{typeof(push!), Vector{Int64}, Int64},
    Tuple{typeof(string), Int64},
    Tuple{typeof(getindex), Vector{Int64}, Int64},
    Tuple{typeof(convert), Type{Int64}, Float64},
    Tuple{typeof(==), String, String},
]

println("Building transitive DictMethodTable for intersection cache testing...")
table = populate_transitive(test_sigs)
println("  Methods: $(length(table.methods))")
println("  Intersections: $(length(table.intersections))")
println("  Intersections with env: $(length(table.intersections_with_env))")

registry = TypeIDRegistry()
assign_types!(registry, table)
println("  Registry: $(length(registry.type_to_id)) types")

# ─── Test 1: Build intersection cache ─────────────────────────────────────────

@testset "IntersectionCache construction" begin
    cache = build_intersection_cache(table, registry)
    @test cache.table_size > 0
    @test cache.n_stored >= 0
    println("  Cache: $(cache.n_stored) intersections in table of size $(cache.table_size)")
end

# ─── Test 2: Lookup matches native for all stored intersections ───────────────

@testset "IntersectionCache lookup — ground truth" begin
    cache = build_intersection_cache(table, registry)
    n_correct = 0
    n_missing = 0

    for ((a, b), result) in table.intersections
        id_a = get_type_id(registry, a)
        id_b = get_type_id(registry, b)
        if id_a < 0 || id_b < 0
            continue
        end

        expected_id = safe_get_type_id(registry, result)
        actual_id = lookup_intersection(cache, id_a, id_b)

        if actual_id == expected_id
            n_correct += 1
        else
            n_missing += 1
            if n_missing <= 3
                println("  MISMATCH: ($a, $b) → expected TypeID=$expected_id, got $actual_id")
            end
        end
    end

    @test n_missing == 0
    @test n_correct >= cache.n_stored
    println("  Verified $n_correct/$( n_correct + n_missing) intersection lookups")
end

# ─── Test 3: Missing intersection returns -1 ─────────────────────────────────

@testset "IntersectionCache — missing returns -1" begin
    cache = build_intersection_cache(table, registry)
    @test lookup_intersection(cache, Int32(99999), Int32(99998)) == Int32(-1)
end

# ─── Test 4: WasmGC module builds and validates ──────────────────────────────

@testset "IntersectionCache WasmGC module" begin
    result = build_intersection_module(table, registry)
    @test length(result.bytes) > 0
    println("  Module size: $(length(result.bytes)) bytes")

    tmpfile = joinpath(tempdir(), "test_intersection.wasm")
    write(tmpfile, result.bytes)

    validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $tmpfile`, stderr=devnull, stdout=devnull))
        true
    catch
        false
    end
    @test validate_ok
    println("  wasm-tools validate: $(validate_ok ? "PASS" : "FAIL")")
end

# ─── Test 5: Execute intersection_lookup in Node.js ───────────────────────────

@testset "IntersectionCache Node.js execution" begin
    cache = build_intersection_cache(table, registry)
    result = build_intersection_module(table, registry)

    tmpwasm = joinpath(tempdir(), "test_intersection_exec.wasm")
    write(tmpwasm, result.bytes)

    # Collect test cases from the cache
    test_a_ids = Int32[]
    test_b_ids = Int32[]
    expected_results = Int32[]
    for ((a, b), res) in table.intersections
        id_a = get_type_id(registry, a)
        id_b = get_type_id(registry, b)
        if id_a < 0 || id_b < 0
            continue
        end
        push!(test_a_ids, id_a)
        push!(test_b_ids, id_b)
        push!(expected_results, lookup_intersection(cache, id_a, id_b))
    end

    # Add a negative test case
    push!(test_a_ids, Int32(99999))
    push!(test_b_ids, Int32(99998))
    push!(expected_results, Int32(-1))

    if isempty(test_a_ids)
        println("  No intersections to test (cache empty)")
        @test true  # Vacuously true
    else
        js_code = """
        const fs = require('fs');
        const bytes = fs.readFileSync('$tmpwasm');
        WebAssembly.instantiate(bytes).then(({instance}) => {
            const {intersection_lookup, _initialize} = instance.exports;
            _initialize();
            const as = [$(join(test_a_ids, ", "))];
            const bs = [$(join(test_b_ids, ", "))];
            const results = [];
            for (let i = 0; i < as.length; i++) {
                results.push(intersection_lookup(as[i], bs[i]));
            }
            console.log(JSON.stringify(results));
        }).catch(e => {
            console.error("WASM error:", e.message);
            process.exit(1);
        });
        """

        tmpjs = joinpath(tempdir(), "test_intersection.cjs")
        write(tmpjs, js_code)

        output = try
            strip(read(`node $tmpjs`, String))
        catch e
            "ERROR: $e"
        end

        if startswith(output, "ERROR")
            @test false
            println("  Node.js error: $output")
        else
            wasm_results = try
                stripped = strip(output)
                nums = split(stripped[2:end-1], ",")
                Int32[parse(Int32, strip(n)) for n in nums]
            catch
                Int32[]
            end

            n_correct = 0
            for i in 1:min(length(wasm_results), length(expected_results))
                wasm_results[i] == expected_results[i] && (n_correct += 1)
            end

            @test n_correct == length(expected_results)
            println("  Node.js ground truth: $n_correct/$(length(expected_results)) correct")
        end
    end
end

println("\n=== PHASE-2A-010: IntersectionCache tests complete ===")
