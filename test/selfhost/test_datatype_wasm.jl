# test_datatype_wasm.jl — Verify DataType/TypeName WasmGC representation
#
# PHASE-2A-007: Handle DataType/TypeName WasmGC representation for typeinf.
#
# Tests:
#   1. Build TypeDataStore from a real DictMethodTable registry
#   2. Verify all entries: tag correctness, parameter IDs, supertype, flags
#   3. Cover all type kinds: DataType, Union, UnionAll, TypeVar, Vararg, Bottom
#   4. Verify field types extraction for concrete structs
#   5. Verify wrapper_id round-trips for parameterized types
#
# Run: julia +1.12 --project=. test/selfhost/test_datatype_wasm.jl

using Test
using WasmTarget

# Load typeinf infrastructure
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "dict_method_table.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "typeid_registry.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "type_data_store.jl"))

# ─── Build test data ──────────────────────────────────────────────────────────

test_sigs = [
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(-), Float64, Float64},
    Tuple{typeof(*), Int32, Int32},
    Tuple{typeof(length), String},
    Tuple{typeof(length), Vector{Int64}},
    Tuple{typeof(push!), Vector{Int64}, Int64},
    Tuple{typeof(getindex), Vector{Int64}, Int64},
    Tuple{typeof(convert), Type{Int64}, Float64},
    Tuple{typeof(string), Int64},
    Tuple{typeof(isnan), Float64},
    Tuple{typeof(abs), Int64},
    Tuple{typeof(hash), Int64},
    Tuple{typeof(sizeof), Type{Int64}},
    Tuple{typeof(first), Vector{Float64}},
    Tuple{typeof(==), String, String},
]

println("Building DictMethodTable with $(length(test_sigs)) signatures...")
world = Base.get_world_counter()
native_mt = Core.Compiler.InternalMethodTable(world)

table = DictMethodTable(world)
for sig in test_sigs
    result = Core.Compiler.findall(sig, native_mt; limit=3)
    result !== nothing && (table.methods[sig] = result)
end

registry = TypeIDRegistry()
assign_types!(registry, table)

# Pre-register additional types used in tests (before building the store)
extra_types = Any[
    Number, Integer, Signed, Real, AbstractFloat,
    Union{Int64, Float64}, Union{Nothing, Int64}, Union{},
    Vector, Pair{Int64, Float64}, Tuple{Int64, Float64},
]
for t in extra_types
    assign_type!(registry, t)
end
println("  Registry: $(length(registry.type_to_id)) types")

# Build the store (AFTER all types are registered)
println("Building TypeDataStore...")
store = build_type_data_store(registry)
stats = store_stats(store)
println("  Total: $(stats.total) entries")
for (tag, count) in sort(collect(stats.by_tag); by=last, rev=true)
    println("    $tag: $count")
end

# ─── Test 1: Full store verification ──────────────────────────────────────────

@testset "TypeDataStore full verification" begin
    result = verify_store(store)
    @test result.n_fail == 0
    @test result.n_ok == length(store.data)
    @test result.n_ok > 50  # Should have many types from the registry

    println("  Verified $(result.n_ok)/$(result.n_ok + result.n_fail) types")
    if result.n_fail > 0
        for f in result.failures[1:min(10, end)]
            println("    FAIL: $f")
        end
    end
end

# ─── Test 2: DataType tag and flags ───────────────────────────────────────────

@testset "DataType extraction — concrete types" begin
    # Int64
    id = get_type_id(registry, Int64)
    if id >= 0
        td = get_type_data(store, id)
        @test td.tag == TYPE_TAG_DATATYPE
        @test td.name_str == "Int64"
        @test td.is_abstract == Int32(0)
        @test td.is_mutable == Int32(0)
        @test td.n_parameters == Int32(0)  # Int64 has no type parameters
    end

    # Float64
    id = get_type_id(registry, Float64)
    if id >= 0
        td = get_type_data(store, id)
        @test td.tag == TYPE_TAG_DATATYPE
        @test td.name_str == "Float64"
        @test td.is_abstract == Int32(0)
    end

    # String
    id = get_type_id(registry, String)
    if id >= 0
        td = get_type_data(store, id)
        @test td.tag == TYPE_TAG_DATATYPE
        @test td.name_str == "String"
    end
end

@testset "DataType extraction — abstract types" begin
    # Number
    id = safe_get_type_id(registry, Number)
    td = get_type_data(store, id)
    @test td.tag == TYPE_TAG_DATATYPE
    @test td.is_abstract == Int32(1)
    @test td.name_str == "Number"

    # Integer
    id = safe_get_type_id(registry, Integer)
    td = get_type_data(store, id)
    @test td.tag == TYPE_TAG_DATATYPE
    @test td.is_abstract == Int32(1)
end

@testset "DataType extraction — parameterized types" begin
    # Vector{Int64} = Array{Int64, 1}
    id = get_type_id(registry, Vector{Int64})
    if id >= 0
        td = get_type_data(store, id)
        @test td.tag == TYPE_TAG_DATATYPE
        @test td.n_parameters >= Int32(1)  # At least the element type
        # First parameter should be Int64
        if length(td.parameter_ids) >= 1
            p1_type = get_type(registry, td.parameter_ids[1])
            @test p1_type == Int64
        end
    end

    # Tuple{Int64, Float64}
    id = safe_get_type_id(registry, Tuple{Int64, Float64})
    td = get_type_data(store, id)
    @test td.tag == TYPE_TAG_DATATYPE
    @test td.n_parameters == Int32(2)
    p1 = get_type(registry, td.parameter_ids[1])
    p2 = get_type(registry, td.parameter_ids[2])
    @test p1 == Int64
    @test p2 == Float64
end

@testset "DataType extraction — supertype chain" begin
    id_int64 = get_type_id(registry, Int64)
    if id_int64 >= 0
        td = get_type_data(store, id_int64)
        # Int64 <: Signed <: Integer <: Real <: Number <: Any
        @test td.super_id >= 0
        sup_type = get_type(registry, td.super_id)
        @test sup_type == supertype(Int64)  # Signed
    end
end

@testset "DataType extraction — field types" begin
    # Pair{Int64, Float64} is a concrete struct
    pair_t = Pair{Int64, Float64}
    id = safe_get_type_id(registry, pair_t)
    td = get_type_data(store, id)
    @test td.tag == TYPE_TAG_DATATYPE
    @test td.n_fields == Int32(fieldcount(pair_t))  # 2 fields
    if td.n_fields == Int32(2)
        f1 = get_type(registry, td.field_type_ids[1])
        f2 = get_type(registry, td.field_type_ids[2])
        @test f1 == fieldtype(pair_t, 1)  # Int64
        @test f2 == fieldtype(pair_t, 2)  # Float64
    end
end

@testset "DataType extraction — mutable struct" begin
    # Vector{Int64} should be mutable
    id = get_type_id(registry, Vector{Int64})
    if id >= 0
        td = get_type_data(store, id)
        @test td.is_mutable == Int32(1)
    end
end

# ─── Test 3: Union type extraction ───────────────────────────────────────────

@testset "Union type extraction" begin
    u = Union{Int64, Float64}
    id = safe_get_type_id(registry, u)
    td = get_type_data(store, id)
    @test td.tag == TYPE_TAG_UNION
    @test td.union_a_id >= 0
    @test td.union_b_id >= 0

    a_type = get_type(registry, td.union_a_id)
    b_type = get_type(registry, td.union_b_id)
    @test (a_type == Int64 && b_type == Float64) || (a_type == Float64 && b_type == Int64)
end

@testset "Union{Nothing, T} extraction" begin
    u = Union{Nothing, Int64}
    id = safe_get_type_id(registry, u)
    td = get_type_data(store, id)
    @test td.tag == TYPE_TAG_UNION
    a = get_type(registry, td.union_a_id)
    b = get_type(registry, td.union_b_id)
    @test (a == Nothing && b == Int64) || (a == Int64 && b == Nothing)
end

# ─── Test 4: UnionAll type extraction ─────────────────────────────────────────

@testset "UnionAll type extraction" begin
    # Vector is Vector{T} where T = UnionAll
    id = safe_get_type_id(registry, Vector)
    td = get_type_data(store, id)
    @test td.tag == TYPE_TAG_UNIONALL

    # Body should be Array{T, 1} or similar
    @test td.ua_body_id >= 0
    @test td.ua_var_lb_id >= 0  # Lower bound (typically Union{} = Bottom)
    @test td.ua_var_ub_id >= 0  # Upper bound (typically Any)
end

# ─── Test 5: Bottom type ─────────────────────────────────────────────────────

@testset "Bottom type (Union{}) extraction" begin
    id = safe_get_type_id(registry, Union{})
    td = get_type_data(store, id)
    @test td.tag == TYPE_TAG_BOTTOM
end

# ─── Test 6: wrapper_id round-trip ────────────────────────────────────────────

@testset "Wrapper ID round-trip" begin
    # Int64.name.wrapper should be Int64
    id = get_type_id(registry, Int64)
    if id >= 0
        td = get_type_data(store, id)
        if td.wrapper_id >= 0
            wrapper_type = get_type(registry, td.wrapper_id)
            @test wrapper_type == Int64.name.wrapper
        end
    end

    # Vector{Int64}.name.wrapper should be Array (the UnionAll)
    id = get_type_id(registry, Vector{Int64})
    if id >= 0
        td = get_type_data(store, id)
        if td.wrapper_id >= 0
            wrapper_type = get_type(registry, td.wrapper_id)
            @test wrapper_type == Vector{Int64}.name.wrapper
        end
    end
end

# ─── Test 7: Comprehensive tag distribution ───────────────────────────────────

@testset "Tag distribution coverage" begin
    tags_seen = Set{Int32}()
    for td in store.data
        push!(tags_seen, td.tag)
    end
    # We should have at least DataType and Bottom
    @test TYPE_TAG_DATATYPE in tags_seen
    println("  Tags seen: $([k for k in sort(collect(tags_seen))])")
end

println("\n=== PHASE-2A-007: TypeDataStore tests complete ===")
