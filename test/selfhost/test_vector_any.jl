# Test Vector{Any} codegen for WasmTarget.jl self-hosting
# Story: PHASE-1-004
# Tests Vector{Any}: length, getindex, setindex!, iterate
# Ground truth: each test function is run natively FIRST, then compiled to WASM

using Test
include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget

# ============================================================================
# Vector{Any} — basic operations
# ============================================================================

function vec_any_length()::Int64
    v = Any[Int64(1), Int64(2), Int64(3)]
    return Int64(length(v))
end

function vec_any_getindex()::Int64
    v = Any[Int64(42), Int64(99)]
    return v[1]::Int64
end

function vec_any_getindex2()::Int64
    v = Any[Int64(42), Int64(99)]
    return v[2]::Int64
end

function vec_any_setindex()::Int64
    v = Any[Int64(0), Int64(0)]
    v[1] = Int64(42)
    v[2] = Int64(99)
    return v[1]::Int64 + v[2]::Int64
end

# ============================================================================
# Vector{Any} — iteration with type assert
# ============================================================================

function vec_any_sum()::Int64
    v = Any[Int64(10), Int64(20), Int64(30)]
    s = Int64(0)
    for x in v
        s += x::Int64
    end
    return s
end

# ============================================================================
# Run all tests
# ============================================================================

@testset "Vector{Any} Codegen (PHASE-1-004)" begin
    @testset "length" begin
        r = compare_julia_wasm(vec_any_length)
        @test r.pass
        println("  vec_any_length: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "getindex [1]" begin
        r = compare_julia_wasm(vec_any_getindex)
        @test r.pass
        println("  vec_any_getindex: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "getindex [2]" begin
        r = compare_julia_wasm(vec_any_getindex2)
        @test r.pass
        println("  vec_any_getindex2: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "setindex!" begin
        r = compare_julia_wasm(vec_any_setindex)
        @test r.pass
        println("  vec_any_setindex: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "iterate with sum" begin
        r = compare_julia_wasm(vec_any_sum)
        @test r.pass
        println("  vec_any_sum: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end
end
