# PHASE-1-V02: Validate nested mutable struct compilation
# Tests mutable structs with Dict, Vector, Any, Union{Nothing,T} fields.
# Tests nested mutable structs up to 3 levels deep.
#
# Ground truth: all functions verified against native Julia output.

using Test

include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget

# ============================================================================
# Type definitions
# ============================================================================

mutable struct MPoint
    x::Int64
    y::Int64
end

mutable struct MBox
    inner::MPoint
    label::Int64
end

mutable struct AnyBox
    value::Any
    count::Int64
end

mutable struct NullableBox
    value::Union{Nothing, Int64}
    set::Bool
end

mutable struct DictHolder
    data::Dict{Int64, Int64}
    size::Int64
end

mutable struct VecHolder
    items::Vector{Int64}
    count::Int64
end

mutable struct MInner
    value::Int64
end

mutable struct MMiddle
    inner::MInner
    bonus::Int64
end

mutable struct MOuter
    middle::MMiddle
    extra::Int64
end

# ============================================================================
# Test functions
# ============================================================================

function make_mpoint()::Int64
    p = MPoint(Int64(3), Int64(4))
    return p.x + p.y
end

function mutate_mpoint()::Int64
    p = MPoint(Int64(0), Int64(0))
    p.x = Int64(10)
    p.y = Int64(20)
    return p.x + p.y
end

function nested_mutable()::Int64
    p = MPoint(Int64(5), Int64(6))
    b = MBox(p, Int64(100))
    return b.inner.x + b.inner.y + b.label
end

function any_field()::Int64
    b = AnyBox(Int64(42), Int64(1))
    return b.value::Int64 + b.count
end

function nullable_field()::Int64
    b = NullableBox(nothing, false)
    b.value = Int64(77)
    b.set = true
    return b.set ? b.value::Int64 : Int64(-1)
end

function dict_field()::Int64
    d = Dict{Int64, Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(2)] = Int64(20)
    h = DictHolder(d, Int64(2))
    return h.data[Int64(1)] + h.data[Int64(2)] + h.size
end

function vec_field()::Int64
    v = Int64[10, 20, 30]
    h = VecHolder(v, Int64(3))
    return h.items[1] + h.items[2] + h.items[3] + h.count
end

function deep_nested()::Int64
    i = MInner(Int64(10))
    m = MMiddle(i, Int64(20))
    o = MOuter(m, Int64(30))
    return o.middle.inner.value + o.middle.bonus + o.extra
end

# ============================================================================
# Run all tests
# ============================================================================

@testset "Nested Mutable Structs (PHASE-1-V02)" begin
    @testset "Simple mutable struct" begin
        r = compare_julia_wasm(make_mpoint)
        @test r.pass
        println("  make_mpoint: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Field mutation" begin
        r = compare_julia_wasm(mutate_mpoint)
        @test r.pass
        println("  mutate_mpoint: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Nested mutable (2 levels)" begin
        r = compare_julia_wasm(nested_mutable)
        @test r.pass
        println("  nested_mutable: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Any-typed field" begin
        r = compare_julia_wasm(any_field)
        @test r.pass
        println("  any_field: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Union{Nothing,T} field" begin
        r = compare_julia_wasm(nullable_field)
        @test r.pass
        println("  nullable_field: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{K,V} field" begin
        r = compare_julia_wasm(dict_field)
        @test r.pass
        println("  dict_field: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Vector{T} field" begin
        r = compare_julia_wasm(vec_field)
        @test r.pass
        println("  vec_field: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Deep nested (3 levels)" begin
        r = compare_julia_wasm(deep_nested)
        @test r.pass
        println("  deep_nested: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end
end

println("\n=== PHASE-1-V02: All nested mutable struct tests complete ===")
