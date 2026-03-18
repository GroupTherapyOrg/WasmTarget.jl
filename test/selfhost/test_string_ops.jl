# PHASE-1-006: Test string operations codegen
# Documents current string operation status for self-hosting.
#
# WORKING: length, sizeof, ==, * concat (when returning Int)
# BROKEN: String return values, startswith, contains
# Root cause: String return type signature mismatch (i64 vs ref)

using Test

include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget

# ============================================================================
# WORKING string operations (return Int)
# ============================================================================

@testset "String Operations (PHASE-1-006)" begin
    @testset "string length" begin
        f_strlen(x::Int64) = begin
            s = "hello world"
            length(s) + x
        end
        r = compare_julia_wasm(f_strlen, Int64(3))
        @test r.pass
        println("  f_strlen(3): Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "string sizeof" begin
        f_sizeof(x::Int64) = begin
            s = "hello"
            Int64(sizeof(s))
        end
        r = compare_julia_wasm(f_sizeof, Int64(0))
        @test r.pass
        println("  f_sizeof(0): Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "string equality ==" begin
        f_streq(x::Int64) = begin
            "hello" == "hello" ? Int64(1) : Int64(0)
        end
        r = compare_julia_wasm(f_streq, Int64(0))
        @test r.pass
        println("  f_streq(0): Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "string inequality ==" begin
        f_strneq(x::Int64) = begin
            "hello" == "world" ? Int64(1) : Int64(0)
        end
        r = compare_julia_wasm(f_strneq, Int64(0))
        @test r.pass
        println("  f_strneq(0): Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "string concat * returning length" begin
        f_concat_len(x::Int64) = begin
            s = "hello" * " " * "world"
            Int64(length(s))
        end
        r = compare_julia_wasm(f_concat_len, Int64(0))
        @test r.pass
        println("  f_concat_len(0): Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end

    @testset "string literal in Dict key" begin
        f_dict_str(x::Int64) = begin
            d = Dict{String, Int64}()
            d["a"] = Int64(1)
            d["b"] = Int64(2)
            d["a"] + d["b"]
        end
        r = compare_julia_wasm(f_dict_str, Int64(0))
        @test r.pass
        println("  f_dict_str(0): Native=$(r.expected), Wasm=$(r.actual) — $(r.pass ? "CORRECT" : "MISMATCH")")
    end
end

println("\n=== PHASE-1-006: String ops tests complete ===")
println("WORKING: length, sizeof, ==, * concat (Int return), Dict{String,...}")
println("KNOWN BUGS: String return values (type mismatch), startswith (stubbed)")
