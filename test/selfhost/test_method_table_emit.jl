# PHASE-2A-002: Test method table emission as WasmGC globals
#
# Run: julia +1.12 --project=. test/selfhost/test_method_table_emit.jl

using WasmTarget
using Test, JSON, Dates

# Load typeinf infrastructure
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "ccall_stubs.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "ccall_replacements.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "dict_method_table.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeid_registry.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "method_table_emit.jl"))

println("=" ^ 70)
println("PHASE-2A-002: Method Table Emission Tests")
println("=" ^ 70)

# Build a test method table
add_one(x::Int64)::Int64 = x + Int64(1)
double_it(x::Int64)::Int64 = x * Int64(2)
negate_it(x::Int64)::Int64 = -x

test_sigs = Any[
    Tuple{typeof(add_one), Int64},
    Tuple{typeof(double_it), Int64},
    Tuple{typeof(negate_it), Int64},
]

table = populate_transitive(test_sigs)
registry = build_typeid_registry(table)
println("  Method table size: $(length(table.methods))")
println("  TypeID registry size: $(length(registry.id_to_type))")

@testset "Method Table Emission" begin

    @testset "FNV-1a hash" begin
        # Deterministic hash
        @test fnv1a_hash(Int32(0)) == fnv1a_hash(Int32(0))
        # Different inputs produce different hashes
        @test fnv1a_hash(Int32(0)) != fnv1a_hash(Int32(1))
        @test fnv1a_hash(Int32(42)) != fnv1a_hash(Int32(43))
    end

    @testset "Emitter creation" begin
        mod = WasmTarget.WasmModule()
        emitter = create_method_table_emitter(mod, registry)

        @test emitter.result_type_idx >= 0
        @test emitter.i32_array_type_idx >= 0
        @test isempty(emitter.type_to_global)
    end

    @testset "Emit method table entries" begin
        mod = WasmTarget.WasmModule()
        emitter = create_method_table_emitter(mod, registry)
        emit_method_table!(emitter, table)

        n_emitted = length(emitter.type_to_global)
        println("  Emitted $n_emitted globals")
        @test n_emitted > 0
        @test n_emitted <= length(table.methods)

        # Every emitted entry should map to a valid global
        for (type_id, global_idx) in emitter.type_to_global
            @test type_id >= 0
            @test global_idx >= 0
        end
    end

    @testset "Hash table construction" begin
        mod = WasmTarget.WasmModule()
        emitter = create_method_table_emitter(mod, registry)
        emit_method_table!(emitter, table)
        build_hash_table!(emitter)

        stats = get_emit_stats(emitter)
        println("  Hash table size: $(stats.hash_table_size)")
        println("  Hash table entries: $(stats.hash_table_entries)")
        println("  Load factor: $(round(stats.load_factor, digits=2))")

        @test stats.hash_table_size > 0
        @test stats.hash_table_entries == stats.n_globals
        @test stats.load_factor <= 0.6  # Should be ~50% with 2x sizing

        # Verify all entries can be looked up
        for (type_id, expected_global) in emitter.type_to_global
            # Linear probe to find entry
            h = fnv1a_hash(type_id) % emitter.hash_table_size
            found = false
            for _ in 1:emitter.hash_table_size
                key, val = emitter.hash_table[h + 1]
                if key == type_id
                    @test val == Int32(expected_global)
                    found = true
                    break
                elseif key == Int32(-1)
                    break  # Empty slot = not found
                end
                h = (h + 1) % emitter.hash_table_size
            end
            @test found
        end
    end

    @testset "Module serialization (wasm-tools validate)" begin
        mod = WasmTarget.WasmModule()
        emitter = create_method_table_emitter(mod, registry)
        emit_method_table!(emitter, table)

        # Serialize the module
        bytes = WasmTarget.to_bytes(mod)
        @test length(bytes) > 0

        # Write to temp file and validate
        wasm_path = tempname() * ".wasm"
        write(wasm_path, bytes)
        println("  Module size: $(length(bytes)) bytes")

        result = try
            run(pipeline(`wasm-tools validate $wasm_path`, stderr=devnull))
            true
        catch e
            err = try
                read(pipeline(`wasm-tools validate $wasm_path`, stderr=stderr), String)
            catch
                "validation failed"
            end
            println("  Validation error: $(first(string(err), 200))")
            false
        end

        rm(wasm_path, force=true)
        @test result
    end
end

println("\n=== ACCEPTANCE: PASS — all tests passed ===")
