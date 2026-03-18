# PHASE-1-005: Test phi nodes on boxed/Union values
# Verifies that phi nodes where the joined type is Any, Union, or abstract
# correctly box/unbox values at phi boundaries.
#
# Ground truth: all functions verified against native Julia output.

using Test

include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget

# ============================================================================
# Test functions exercising phi-on-Any patterns
# ============================================================================

# 1. Basic: iterate Vector{Any} with typeassert
function phi_vec_any_sum()::Int64
    v = Any[Int64(10), Int64(20), Int64(30)]
    s = Int64(0)
    for x in v
        s += x::Int64
    end
    return s
end

# 2. Conditional in loop with Any values
function phi_any_conditional()::Int64
    v = Any[Int64(1), Int64(2), Int64(3)]
    result = Int64(0)
    for x in v
        val = x::Int64
        if val > Int64(1)
            result += val
        end
    end
    return result
end

# 3. Branch producing different boxed types
function phi_any_branch()::Int64
    v = Any[Int64(10), Int64(20), Int64(30)]
    s = Int64(0)
    for x in v
        y = x::Int64
        if y > Int64(15)
            s += y
        else
            s += Int64(1)
        end
    end
    return s
end

# 4. Phi with nullable — Union{Nothing, Int64}
function phi_nullable()::Int64
    v = Any[Int64(1), Int64(2), Int64(3)]
    last_even = nothing
    for x in v
        val = x::Int64
        if val % Int64(2) == Int64(0)
            last_even = val
        end
    end
    return last_even === nothing ? Int64(-1) : last_even::Int64
end

# 5. Mixed accumulator with bool phi
function phi_mixed_accumulator()::Int64
    v = Any[Int64(10), Int64(20), Int64(30)]
    s = Int64(0)
    found = false
    for x in v
        val = x::Int64
        if val > Int64(15)
            s += val
            found = true
        end
    end
    return found ? s : Int64(-1)
end

# 6. Any-typed value in isa check
function phi_isa_check()::Int64
    x::Any = Int64(42)
    if x isa Int64
        return x + Int64(1)
    else
        return Int64(-1)
    end
end

# ============================================================================
# Run all tests
# ============================================================================

@testset "Phi Nodes on Boxed/Union Values (PHASE-1-005)" begin
    @testset "Vector{Any} iterate + typeassert" begin
        r = compare_julia_wasm(phi_vec_any_sum)
        @test r.pass
        println("  phi_vec_any_sum: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Conditional in loop with Any" begin
        r = compare_julia_wasm(phi_any_conditional)
        @test r.pass
        println("  phi_any_conditional: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Branch with different boxed types" begin
        r = compare_julia_wasm(phi_any_branch)
        @test r.pass
        println("  phi_any_branch: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Nullable Union{Nothing, Int64}" begin
        r = compare_julia_wasm(phi_nullable)
        @test r.pass
        println("  phi_nullable: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Mixed accumulator + bool phi" begin
        r = compare_julia_wasm(phi_mixed_accumulator)
        @test r.pass
        println("  phi_mixed_accumulator: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "isa check on Any-typed value" begin
        r = compare_julia_wasm(phi_isa_check)
        @test r.pass
        println("  phi_isa_check: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end
end

println("\n=== PHASE-1-005: All phi boxed/Union tests complete ===")
