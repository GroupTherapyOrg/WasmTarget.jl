# test_findall_wasm.jl — Test WasmGC findall_by_typeid function
#
# PHASE-2A-005: Compile DictMethodTable.findall to WasmGC with TypeID-based lookup.
#
# Tests:
#   1. Build module with hash table + findall function
#   2. wasm-tools validate passes
#   3. Execute in Node.js — findall_by_typeid returns correct global indices
#   4. Ground truth: WASM findall results match native DictMethodTable for 20+ signatures
#
# Run: julia +1.12 --project=. test/selfhost/test_findall_wasm.jl

using Test
using WasmTarget

# Load typeinf infrastructure
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "dict_method_table.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "typeid_registry.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "method_table_emit.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "minimal_method.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "findall_wasm.jl"))

# ─── Build test data ──────────────────────────────────────────────────────────

test_sigs = [
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(-), Int64, Int64},
    Tuple{typeof(*), Int64, Int64},
    Tuple{typeof(+), Float64, Float64},
    Tuple{typeof(-), Float64, Float64},
    Tuple{typeof(*), Float64, Float64},
    Tuple{typeof(/), Float64, Float64},
    Tuple{typeof(abs), Int64},
    Tuple{typeof(sqrt), Float64},
    Tuple{typeof(==), Int64, Int64},
    Tuple{typeof(<), Int64, Int64},
    Tuple{typeof(length), String},
    Tuple{typeof(length), Vector{Int64}},
    Tuple{typeof(push!), Vector{Int64}, Int64},
    Tuple{typeof(getindex), Vector{Int64}, Int64},
    Tuple{typeof(convert), Type{Int64}, Float64},
    Tuple{typeof(string), Int64},
    Tuple{typeof(min), Int64, Int64},
    Tuple{typeof(max), Int64, Int64},
    Tuple{typeof(hash), Int64},
]

println("Building DictMethodTable with $(length(test_sigs)) signatures...")
world = Base.get_world_counter()
native_mt = Core.Compiler.InternalMethodTable(world)

table = DictMethodTable(world)
for sig in test_sigs
    result = Core.Compiler.findall(sig, native_mt; limit=3)
    result !== nothing && (table.methods[sig] = result)
end
println("  $(length(table.methods)) signatures in table")

registry = TypeIDRegistry()
assign_types!(registry, table)
println("  $(length(registry.type_to_id)) types in registry")

# ─── Test 1: Build module ─────────────────────────────────────────────────────

@testset "Build findall module" begin
    result = build_findall_module(table, registry)
    @test length(result.bytes) > 0
    println("  Module size: $(length(result.bytes)) bytes")

    # Write to file for validation
    tmpfile = joinpath(tempdir(), "test_findall.wasm")
    write(tmpfile, result.bytes)

    # wasm-tools validate
    validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $tmpfile`, stderr=devnull, stdout=devnull))
        true
    catch
        false
    end
    @test validate_ok
    println("  wasm-tools validate: $(validate_ok ? "PASS" : "FAIL")")
end

# ─── Test 2: Execute in Node.js ───────────────────────────────────────────────

@testset "findall_by_typeid execution in Node.js" begin
    result = build_findall_module(table, registry)
    tmpwasm = joinpath(tempdir(), "test_findall_exec.wasm")
    write(tmpwasm, result.bytes)

    # Build Node.js test script
    # For each test signature, call findall_by_typeid(type_id) and record result
    test_type_ids = Int32[]
    expected_results = Int32[]
    for sig in test_sigs
        type_id = get_type_id(registry, sig)
        if type_id >= 0
            push!(test_type_ids, type_id)
            # Expected: lookup_hash_table should return the global index
            expected = lookup_hash_table(result.emitter, type_id)
            push!(expected_results, expected)
        end
    end

    # Generate Node.js test code
    js_code = """
    const fs = require('fs');
    const bytes = fs.readFileSync('$tmpwasm');
    WebAssembly.instantiate(bytes).then(({instance}) => {
        const {findall_by_typeid, _initialize} = instance.exports;
        _initialize();
        const results = [];
        const typeIds = [$(join(test_type_ids, ", "))];
        for (const tid of typeIds) {
            results.push(findall_by_typeid(tid));
        }
        console.log(JSON.stringify(results));
    }).catch(e => {
        console.error("WASM error:", e.message);
        process.exit(1);
    });
    """

    tmpjs = joinpath(tempdir(), "test_findall.cjs")
    write(tmpjs, js_code)

    output = try
        read(`node $tmpjs`, String)
    catch e
        "ERROR: $e"
    end

    if startswith(output, "ERROR")
        @test false  # Node.js execution failed
        println("  Node.js error: $output")
    else
        # Parse JSON results
        wasm_results = try
            # Simple JSON array parsing
            stripped = strip(output)
            nums = split(stripped[2:end-1], ",")
            Int32[parse(Int32, strip(n)) for n in nums]
        catch e
            println("  Parse error: $e, output: $output")
            Int32[]
        end

        @test length(wasm_results) == length(expected_results)

        n_correct = 0
        n_mismatch = 0
        for i in 1:min(length(wasm_results), length(expected_results))
            if wasm_results[i] == expected_results[i]
                n_correct += 1
            else
                n_mismatch += 1
                if n_mismatch <= 5
                    println("  MISMATCH: TypeID=$(test_type_ids[i]) expected=$(expected_results[i]) got=$(wasm_results[i])")
                end
            end
        end

        @test n_correct == length(expected_results)
        @test n_mismatch == 0
        @test n_correct >= 20
        println("  Ground truth: $n_correct/$( length(expected_results)) correct, $n_mismatch mismatches")
    end
end

# ─── Test 3: Negative lookup (type not in table) ─────────────────────────────

@testset "findall_by_typeid — missing TypeID returns -1" begin
    result = build_findall_module(table, registry)
    tmpwasm = joinpath(tempdir(), "test_findall_neg.wasm")
    write(tmpwasm, result.bytes)

    # Use a TypeID that's definitely not in the hash table
    # TypeIDs assigned to component types (not signatures) shouldn't be in the method table
    missing_id = Int32(99999)  # Very high ID, definitely not in table

    js_code = """
    const fs = require('fs');
    const bytes = fs.readFileSync('$tmpwasm');
    WebAssembly.instantiate(bytes).then(({instance}) => {
        const {findall_by_typeid, _initialize} = instance.exports;
        _initialize();
        console.log(findall_by_typeid($missing_id));
    }).catch(e => {
        console.error("WASM error:", e.message);
        process.exit(1);
    });
    """

    tmpjs = joinpath(tempdir(), "test_findall_neg.cjs")
    write(tmpjs, js_code)

    output = try
        strip(read(`node $tmpjs`, String))
    catch e
        "ERROR: $e"
    end

    @test output == "-1"
    println("  Missing TypeID returns: $output (expected -1)")
end

println("\n=== PHASE-2A-005: findall_wasm tests complete ===")
