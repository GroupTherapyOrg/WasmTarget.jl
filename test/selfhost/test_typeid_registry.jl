# PHASE-2A-001: Test TypeID registry
#
# Run: julia +1.12 --project=. test/selfhost/test_typeid_registry.jl

using WasmTarget
using Test, JSON, Dates

# Load typeinf infrastructure
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "ccall_stubs.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "ccall_replacements.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "dict_method_table.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "typeid_registry.jl"))

println("=" ^ 70)
println("PHASE-2A-001: TypeID Registry Tests")
println("=" ^ 70)

@testset "TypeID Registry" begin
    # ─── Basic functionality ────────────────────────────────────────────
    @testset "Basic assign and lookup" begin
        reg = TypeIDRegistry()
        id1 = assign_type!(reg, Int64)
        id2 = assign_type!(reg, Float64)
        id3 = assign_type!(reg, String)

        @test id1 == Int32(0)
        @test id2 == Int32(1)
        @test id3 == Int32(2)

        # Duplicate assignment returns same ID
        @test assign_type!(reg, Int64) == id1
        @test assign_type!(reg, Float64) == id2

        # Reverse lookup
        @test get_type(reg, id1) === Int64
        @test get_type(reg, id2) === Float64
        @test get_type(reg, id3) === String

        # has_type
        @test has_type(reg, Int64)
        @test has_type(reg, Float64)
        @test !has_type(reg, Bool)

        # get_type_id
        @test get_type_id(reg, Int64) == id1
        @test get_type_id(reg, Bool) == Int32(-1)
    end

    # ─── Compound types ─────────────────────────────────────────────────
    @testset "Compound tuple types" begin
        reg = TypeIDRegistry()
        sig = Tuple{typeof(+), Int64, Int64}
        id = assign_type!(reg, sig)

        @test id >= Int32(0)
        @test get_type(reg, id) === sig
        @test get_type_id(reg, sig) == id
    end

    # ─── Build from DictMethodTable ─────────────────────────────────────
    @testset "Build from DictMethodTable" begin
        # Create a small method table
        add_one(x::Int64)::Int64 = x + Int64(1)
        table = populate_transitive([Tuple{typeof(add_one), Int64}])

        reg = build_typeid_registry(table)
        stats = registry_stats(reg)

        println("  Total types: $(stats.total_types)")
        println("  Atomic: $(stats.n_atomic)")
        println("  Compound: $(stats.n_compound)")

        @test stats.total_types > 0

        # All method table keys should have IDs
        for sig in keys(table.methods)
            @test has_type(reg, sig)
        end

        # Common types should have IDs
        @test has_type(reg, Int64)
        @test has_type(reg, Any)
        @test has_type(reg, Nothing)

        # Round-trip for all types
        for (t, id) in reg.type_to_id
            @test get_type(reg, id) === t
        end
    end

    # ─── Build from full typeinf scope ──────────────────────────────────
    @testset "Full typeinf scope registry" begin
        # Load the scope results from PHASE-2-PREP-001
        scope_path = joinpath(@__DIR__, "typeinf_scope_results.json")
        if isfile(scope_path)
            scope = JSON.parsefile(scope_path)
            println("  Phase 2 scope: $(scope["combined"]["method_signatures"]) sigs")
        end

        # Build with typeinf entries
        add_one(x::Int64)::Int64 = x + Int64(1)
        sigs = Any[
            Tuple{typeof(add_one), Int64},
            Tuple{typeof(Core.Compiler.typeinf), WasmInterpreter, Core.Compiler.InferenceState},
            Tuple{typeof(Core.Compiler.findall), Type, DictMethodTable},
        ]

        table = populate_transitive(sigs)
        reg = build_typeid_registry(table)
        stats = registry_stats(reg)

        println("  Types registered: $(stats.total_types)")
        println("  Method sigs in table: $(length(table.methods))")

        @test stats.total_types >= length(table.methods)

        # Every method sig should have an ID
        missing_count = 0
        for sig in keys(table.methods)
            if !has_type(reg, sig)
                missing_count += 1
            end
        end
        @test missing_count == 0
    end

    # ─── Unique IDs ─────────────────────────────────────────────────────
    @testset "All IDs unique" begin
        reg = TypeIDRegistry()
        types = [Int64, Float64, String, Bool, Nothing, Any, Symbol, Char,
                 Tuple{Int64}, Tuple{Float64, Int64}, Vector{Int64}]

        for t in types
            assign_type!(reg, t)
        end

        ids = [get_type_id(reg, t) for t in types]
        @test length(unique(ids)) == length(ids)
        @test all(id -> id >= 0, ids)
    end
end

# ─── Save results ───────────────────────────────────────────────────────────
println("\n=== ACCEPTANCE: TypeIDRegistry assigns unique i32 to all types ===")
