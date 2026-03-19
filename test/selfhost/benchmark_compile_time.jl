# benchmark_compile_time.jl — PHASE-3-T03: Compile time benchmarks
#
# Benchmark the full self-hosting pipeline (source → WASM) for representative
# functions. Target: < 3 seconds for simple functions (per spec §5.7.6).
#
# Run: julia +1.12 --project=. test/selfhost/benchmark_compile_time.jl

using Test
using WasmTarget
using Printf

include(joinpath(@__DIR__, "..", "utils.jl"))

println("=== PHASE-3-T03: Compile Time Benchmarks ===\n")

# ═══════════════════════════════════════════════════════════════════════════════
# Benchmark functions (varying complexity)
# ═══════════════════════════════════════════════════════════════════════════════

bench_add(x::Int64, y::Int64)::Int64 = x + y
bench_square(x::Int64)::Int64 = x * x + Int64(1)
bench_abs(x::Int64)::Int64 = x >= Int64(0) ? x : -x
bench_sum_n(n::Int64)::Int64 = begin
    s = Int64(0); i = Int64(1)
    while i <= n; s += i; i += Int64(1); end; s
end
bench_factorial(n::Int64)::Int64 = begin
    f = Int64(1); i = Int64(1)
    while i <= n; f *= i; i += Int64(1); end; f
end
bench_fma(a::Float64, b::Float64, c::Float64)::Float64 = a * b + c
bench_poly(x::Int64)::Int64 = x*x*x + Int64(2)*x*x + Int64(3)*x + Int64(4)
bench_min3(a::Int64, b::Int64, c::Int64)::Int64 = begin
    m = a < b ? a : b; m < c ? m : c
end

benchmarks = [
    ("add (2 args)",      bench_add,       (Int64, Int64)),
    ("square+1",          bench_square,    (Int64,)),
    ("abs (conditional)",  bench_abs,       (Int64,)),
    ("sum_n (loop)",      bench_sum_n,     (Int64,)),
    ("factorial (loop)",  bench_factorial,  (Int64,)),
    ("fma (float)",       bench_fma,       (Float64, Float64, Float64)),
    ("poly (nested)",     bench_poly,      (Int64,)),
    ("min3 (multi-cond)", bench_min3,      (Int64, Int64, Int64)),
]

# ═══════════════════════════════════════════════════════════════════════════════
# Phase breakdown: code_typed → compile_from_codeinfo → to_bytes → validate
# ═══════════════════════════════════════════════════════════════════════════════

println("--- Phase-by-phase timing (cold) ---\n")
println("  Function               | code_typed | compile  | to_bytes | total    | size")
println("  " * "-"^85)

cold_times = Dict{String, Float64}()

for (name, f, argtypes) in benchmarks
    # Cold timings (include JIT compilation of WasmTarget itself)
    t_typed = @elapsed begin
        ci, ret = Base.code_typed(f, argtypes)[1]
    end
    ci, ret = Base.code_typed(f, argtypes)[1]

    t_compile = @elapsed begin
        mod = WasmTarget.compile_module_from_ir([(ci, ret, argtypes, name)])
    end
    mod = WasmTarget.compile_module_from_ir([(ci, ret, argtypes, name)])

    t_bytes = @elapsed begin
        bytes = WasmTarget.to_bytes(mod)
    end
    bytes = WasmTarget.to_bytes(mod)

    total = t_typed + t_compile + t_bytes
    cold_times[name] = total

    println(@sprintf("  %-24s| %7.3fs   | %7.3fs | %7.3fs | %7.3fs  | %d B", name, t_typed, t_compile, t_bytes, total, length(bytes)))
end

# ═══════════════════════════════════════════════════════════════════════════════
# Warm timings (after JIT warmup)
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Warm timings (after JIT warmup) ---\n")
println("  Function               | code_typed | compile  | to_bytes | total")
println("  " * "-"^75)

warm_times = Dict{String, Float64}()

for (name, f, argtypes) in benchmarks
    # Warm: run 3 times, take minimum
    best = Inf
    best_typed = Inf
    best_compile = Inf
    best_bytes = Inf

    for _ in 1:3
        t_typed = @elapsed begin
            ci, ret = Base.code_typed(f, argtypes)[1]
        end
        ci, ret = Base.code_typed(f, argtypes)[1]

        t_compile = @elapsed begin
            mod = WasmTarget.compile_module_from_ir([(ci, ret, argtypes, name)])
        end
        mod = WasmTarget.compile_module_from_ir([(ci, ret, argtypes, name)])

        t_bytes = @elapsed begin
            bytes = WasmTarget.to_bytes(mod)
        end

        total = t_typed + t_compile + t_bytes
        if total < best
            best = total
            best_typed = t_typed
            best_compile = t_compile
            best_bytes = t_bytes
        end
    end

    warm_times[name] = best
    println(@sprintf("  %-24s| %7.3fs   | %7.3fs | %7.3fs | %7.3fs", name, best_typed, best_compile, best_bytes, best))
end

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Summary ---")
max_cold = maximum(values(cold_times))
max_warm = maximum(values(warm_times))
avg_cold = sum(values(cold_times)) / length(cold_times)
avg_warm = sum(values(warm_times)) / length(warm_times)

println("  Cold: max=$(round(max_cold, digits=3))s, avg=$(round(avg_cold, digits=3))s")
println("  Warm: max=$(round(max_warm, digits=3))s, avg=$(round(avg_warm, digits=3))s")
println("  Target: < 3 seconds for simple functions")
println("  Result: $(max_warm < 3.0 ? "PASS" : "FAIL") (warm max=$(round(max_warm, digits=3))s)")

# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

@testset "PHASE-3-T03: Compile time benchmarks" begin
    @testset "warm compile time < 3s for all functions" begin
        for (name, t) in warm_times
            @test t < 3.0
        end
    end

    @testset "warm compile time < 1s for simple functions" begin
        # Simple functions (add, square) should be < 1s warm
        @test warm_times["add (2 args)"] < 1.0
        @test warm_times["square+1"] < 1.0
    end
end

println("\n=== PHASE-3-T03 test complete ===")
