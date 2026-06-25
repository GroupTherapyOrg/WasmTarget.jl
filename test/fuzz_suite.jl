# ============================================================================
# Bounded differential fuzz — runs inside the main suite / CI
# ============================================================================
#
# Replays the committed corpus (test/fuzz/corpus) as a regression ratchet, then
# runs a small fixed-seed budget of generated compositions, asserting native==wasm.
# The full machine and the standalone self-fulfilling loop live in test/fuzz/
# (run `julia --project=test/fuzz test/fuzz/run.jl` for deep exploration).
#
# Requires Supposition (test-only dep) + Node.js; skips cleanly without Node.

@testset "Differential fuzz (bounded)" begin
    include(joinpath(@__DIR__, "fuzz", "run.jl"))
    if FuzzHarness.NODE_OK
        @test ci_fuzz_passes(; types = (Int64, Float64), depth = 2, max_examples = 30, seed = 0xCD)
    else
        @info "Differential fuzz skipped — Node.js unavailable"
        @test_skip true
    end
end

# LinearAlgebra MATRIX surface — verified by direct differential sweeps (the
# generator does Vector, not Matrix). run.jl above already loaded the bridge
# modules into this scope.
# Named "Differential fuzz: …" so runtests.jl's fuzz-log echo (which greps for
# "Differential fuzz") surfaces its Pass/Total summary line.
@testset "Differential fuzz: LinearAlgebra matrix" begin
    if FuzzHarness.NODE_OK
        include(joinpath(@__DIR__, "fuzz", "linalg_diff.jl"))
        run_linalg_matrix_tests()
    else
        @info "LinearAlgebra matrix differential skipped — Node.js unavailable"
        @test_skip true
    end
end

# Dates value layer — Date/DateTime values the catalogue generator can't produce.
@testset "Differential fuzz: Dates value layer" begin
    if FuzzHarness.NODE_OK
        include(joinpath(@__DIR__, "fuzz", "dates_diff.jl"))
        run_dates_tests()
    else
        @test_skip true
    end
end

# Random — seeded Xoshiro streams (RNG state the catalogue can't produce).
@testset "Differential fuzz: Random seeded streams" begin
    if FuzzHarness.NODE_OK
        include(joinpath(@__DIR__, "fuzz", "random_diff.jl"))
        run_random_tests()
    else
        @test_skip true
    end
end

# Statistics in-place ops (mean!/median!/quantile!).
@testset "Differential fuzz: Statistics in-place" begin
    if FuzzHarness.NODE_OK
        include(joinpath(@__DIR__, "fuzz", "stats_diff.jl"))
        run_stats_tests()
    else
        @test_skip true
    end
end
