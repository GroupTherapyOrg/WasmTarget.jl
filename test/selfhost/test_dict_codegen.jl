# Test Dict{K,V} codegen for WasmTarget.jl self-hosting
# Story: PHASE-1-002
# Tests Dict constructor, setindex!, getindex, haskey, get, delete!, length
# Ground truth: each test function is run natively FIRST, then compiled to WASM

using Test
include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget

# ============================================================================
# Dict{Int64,Int64} — basic operations
# ============================================================================

function dict_int_constructor()::Int64
    d = Dict{Int64,Int64}()
    return Int64(length(d))
end

function dict_int_setget()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    return d[Int64(1)]
end

function dict_int_multi()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(2)] = Int64(20)
    d[Int64(3)] = Int64(30)
    return d[Int64(1)] + d[Int64(2)] + d[Int64(3)]
end

function dict_int_haskey_true()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    return haskey(d, Int64(1)) ? Int64(1) : Int64(0)
end

function dict_int_haskey_false()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    return haskey(d, Int64(99)) ? Int64(1) : Int64(0)
end

function dict_int_get_default()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    return get(d, Int64(99), Int64(-1))
end

function dict_int_get_found()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(42)
    return get(d, Int64(1), Int64(-1))
end

function dict_int_delete()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(2)] = Int64(20)
    delete!(d, Int64(1))
    return haskey(d, Int64(1)) ? Int64(1) : d[Int64(2)]
end

function dict_int_length()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(2)] = Int64(20)
    d[Int64(3)] = Int64(30)
    return Int64(length(d))
end

function dict_int_overwrite()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10)
    d[Int64(1)] = Int64(99)
    return d[Int64(1)]
end

# ============================================================================
# Dict{String,Int64}
# ============================================================================

function dict_string_key_test()::Int64
    d = Dict{String,Int64}()
    d["hello"] = Int64(42)
    d["world"] = Int64(99)
    return d["hello"] + d["world"]
end

# ============================================================================
# Dict{Symbol,Int64}
# ============================================================================

function dict_symbol_key_test()::Int64
    d = Dict{Symbol,Int64}()
    d[:x] = Int64(10)
    d[:y] = Int64(20)
    return d[:x] + d[:y]
end

# ============================================================================
# Dict{Symbol,Any}
# ============================================================================

function dict_symbol_any_test()::Int64
    d = Dict{Symbol,Any}()
    d[:x] = Int64(10)
    return d[:x]::Int64
end

# ============================================================================
# Run all tests
# ============================================================================

@testset "Dict{K,V} Codegen (PHASE-1-002)" begin
    @testset "Dict{Int64,Int64} — constructor" begin
        r = compare_julia_wasm(dict_int_constructor)
        @test r.pass
        println("  dict_int_constructor: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Int64,Int64} — set/get" begin
        r = compare_julia_wasm(dict_int_setget)
        @test r.pass
        println("  dict_int_setget: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Int64,Int64} — multiple keys" begin
        r = compare_julia_wasm(dict_int_multi)
        @test r.pass
        println("  dict_int_multi: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Int64,Int64} — haskey true" begin
        r = compare_julia_wasm(dict_int_haskey_true)
        @test r.pass
        println("  dict_int_haskey_true: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Int64,Int64} — haskey false" begin
        r = compare_julia_wasm(dict_int_haskey_false)
        @test r.pass
        println("  dict_int_haskey_false: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Int64,Int64} — get default" begin
        r = compare_julia_wasm(dict_int_get_default)
        @test r.pass
        println("  dict_int_get_default: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Int64,Int64} — get found" begin
        r = compare_julia_wasm(dict_int_get_found)
        @test r.pass
        println("  dict_int_get_found: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Int64,Int64} — delete!" begin
        r = compare_julia_wasm(dict_int_delete)
        @test r.pass
        println("  dict_int_delete: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Int64,Int64} — length" begin
        r = compare_julia_wasm(dict_int_length)
        @test r.pass
        println("  dict_int_length: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Int64,Int64} — overwrite" begin
        r = compare_julia_wasm(dict_int_overwrite)
        @test r.pass
        println("  dict_int_overwrite: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{String,Int64}" begin
        r = compare_julia_wasm(dict_string_key_test)
        @test r.pass
        println("  dict_string_key_test: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Symbol,Int64}" begin
        r = compare_julia_wasm(dict_symbol_key_test)
        @test r.pass
        println("  dict_symbol_key_test: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "Dict{Symbol,Any}" begin
        r = compare_julia_wasm(dict_symbol_any_test)
        @test r.pass
        println("  dict_symbol_any_test: Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end
end
