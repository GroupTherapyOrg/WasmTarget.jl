# Test Dict{K,V} iteration codegen for WasmTarget.jl self-hosting
# Story: PHASE-1-003
# Tests iterate(d::Dict), keys(d), values(d), pairs(d)
# Ground truth: each test function is run natively FIRST, then compiled to WASM

using Test
include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget

# ============================================================================
# Dict iteration via values()
# ============================================================================

function dict_values_sum()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(2)] = Int64(20)
    s = Int64(0)
    for v in values(d)
        s += v
    end
    return s
end

function dict_values_sum3()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(2)] = Int64(20)
    d[Int64(3)] = Int64(30)
    s = Int64(0)
    for v in values(d)
        s += v
    end
    return s
end

# ============================================================================
# Dict iteration via pairs (for (k,v) in d)
# ============================================================================

function dict_pairs_sum2()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(2)] = Int64(20)
    s = Int64(0)
    for (k, v) in d
        s += k * v
    end
    return s
end

function dict_pairs_sum3()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(2)] = Int64(20)
    d[Int64(3)] = Int64(30)
    s = Int64(0)
    for (k, v) in d
        s += k * v
    end
    return s
end

# ============================================================================
# Dict iteration via keys() — k is used in body
# ============================================================================

function dict_keys_sum()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(2)] = Int64(20)
    s = Int64(0)
    for k in keys(d)
        s += k
    end
    return s
end

function dict_keys_sum3()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(2)] = Int64(20)
    d[Int64(3)] = Int64(30)
    s = Int64(0)
    for k in keys(d)
        s += k
    end
    return s
end

# ============================================================================
# Dict{String,Int64} iteration
# ============================================================================

function dict_string_values_sum()::Int64
    d = Dict{String,Int64}()
    d["a"] = Int64(1)
    d["b"] = Int64(2)
    d["c"] = Int64(3)
    s = Int64(0)
    for v in values(d)
        s += v
    end
    return s
end

# ============================================================================
# Run all tests
# ============================================================================

@testset "Dict Iteration Codegen (PHASE-1-003)" begin
    @testset "values() — 2 entries" begin
        r = compare_julia_wasm(dict_values_sum)
        @test r.pass
        println("  dict_values_sum: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "values() — 3 entries" begin
        r = compare_julia_wasm(dict_values_sum3)
        @test r.pass
        println("  dict_values_sum3: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "pairs — 2 entries (k*v)" begin
        r = compare_julia_wasm(dict_pairs_sum2)
        @test r.pass
        println("  dict_pairs_sum2: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "pairs — 3 entries (k*v)" begin
        r = compare_julia_wasm(dict_pairs_sum3)
        @test r.pass
        println("  dict_pairs_sum3: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "keys() — 2 entries" begin
        r = compare_julia_wasm(dict_keys_sum)
        @test r.pass
        println("  dict_keys_sum: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "keys() — 3 entries" begin
        r = compare_julia_wasm(dict_keys_sum3)
        @test r.pass
        println("  dict_keys_sum3: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{String,Int64} values()" begin
        r = compare_julia_wasm(dict_string_values_sum)
        @test r.pass
        println("  dict_string_values_sum: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end
end
