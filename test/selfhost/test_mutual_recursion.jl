# Test mutual recursion compilation for WasmTarget.jl self-hosting
# Story: PHASE-1-V01
# Tests 2-function and 3-function mutual recursion cycles

using Test
include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget

# ============================================================================
# 2-function mutual recursion: is_even / is_odd
# ============================================================================

is_even(n::Int64)::Int64 = n == Int64(0) ? Int64(1) : is_odd(n - Int64(1))
is_odd(n::Int64)::Int64 = n == Int64(0) ? Int64(0) : is_even(n - Int64(1))

# ============================================================================
# 3-function mutual recursion: f_a / f_b / f_c
# ============================================================================

f_a(n::Int64)::Int64 = n <= Int64(0) ? Int64(1) : f_b(n - Int64(1))
f_b(n::Int64)::Int64 = n <= Int64(0) ? Int64(2) : f_c(n - Int64(1))
f_c(n::Int64)::Int64 = n <= Int64(0) ? Int64(3) : f_a(n - Int64(1))

# ============================================================================
# Run tests
# ============================================================================

@testset "Mutual Recursion (PHASE-1-V01)" begin
    @testset "2-function cycle: is_even/is_odd" begin
        bytes = WasmTarget.compile_multi([
            (is_even, (Int64,)),
            (is_odd, (Int64,)),
        ])
        imports = Dict("Math" => Dict("pow" => "Math.pow"))

        for (n, expected) in [(Int64(0), 1), (Int64(1), 0), (Int64(10), 1), (Int64(7), 0)]
            actual = run_wasm_with_imports(bytes, "is_even", imports, n)
            @test actual == expected
            println("  is_even($n): Native=$expected, Wasm=$actual — $(actual == expected ? "CORRECT" : "MISMATCH")")
        end

        for (n, expected) in [(Int64(0), 0), (Int64(1), 1), (Int64(5), 1), (Int64(6), 0)]
            actual = run_wasm_with_imports(bytes, "is_odd", imports, n)
            @test actual == expected
            println("  is_odd($n): Native=$expected, Wasm=$actual — $(actual == expected ? "CORRECT" : "MISMATCH")")
        end
    end

    @testset "3-function cycle: f_a/f_b/f_c" begin
        bytes = WasmTarget.compile_multi([
            (f_a, (Int64,)),
            (f_b, (Int64,)),
            (f_c, (Int64,)),
        ])
        imports = Dict("Math" => Dict("pow" => "Math.pow"))

        for (n, expected) in [(Int64(0), 1), (Int64(6), 1), (Int64(7), 2), (Int64(8), 3)]
            actual = run_wasm_with_imports(bytes, "f_a", imports, n)
            @test actual == expected
            println("  f_a($n): Native=$(f_a(n)), Wasm=$actual — $(actual == expected ? "CORRECT" : "MISMATCH")")
        end
    end
end
