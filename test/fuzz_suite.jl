# ============================================================================
# Bounded differential fuzz — runs inside the main suite / CI
# ============================================================================
#
# Replays the committed corpus (test/fuzz/corpus) as a regression ratchet, then
# runs a small fixed-seed budget of generated compositions, asserting native==wasm.
# The full machine and the standalone self-fulfilling loop live in test/fuzz/
# (run `julia --project=test/fuzz test/fuzz/run.jl` for deep exploration).
#
# Requires Supposition (test-only dep) + Node.js (test/wasm_runner.jl errors without it).

@testset "Differential fuzz (bounded)" begin
    include(joinpath(@__DIR__, "fuzz", "run.jl"))
    @test ci_fuzz_passes(; types = (Int64, Float64), depth = 2, max_examples = 30, seed = 0xCD)
end

# LinearAlgebra MATRIX surface — verified by direct differential sweeps (the
# generator does Vector, not Matrix). run.jl above already loaded the bridge
# modules into this scope.
# Named "Differential fuzz: …" so runtests.jl's fuzz-log echo (which greps for
# "Differential fuzz") surfaces its Pass/Total summary line.
@testset "Differential fuzz: LinearAlgebra matrix" begin
    include(joinpath(@__DIR__, "fuzz", "linalg_diff.jl"))
    run_linalg_matrix_tests()
end

# Dates value layer — Date/DateTime values the catalogue generator can't produce.
@testset "Differential fuzz: Dates value layer" begin
    include(joinpath(@__DIR__, "fuzz", "dates_diff.jl"))
    run_dates_tests()
end

# Random — seeded Xoshiro streams (RNG state the catalogue can't produce).
@testset "Differential fuzz: Random seeded streams" begin
    include(joinpath(@__DIR__, "fuzz", "random_diff.jl"))
    run_random_tests()
end

# Statistics in-place ops (mean!/median!/quantile!).
@testset "Differential fuzz: Statistics in-place" begin
    include(joinpath(@__DIR__, "fuzz", "stats_diff.jl"))
    run_stats_tests()
end

# SparseArrays foundation — sparse construction + read/reduce/matvec.
@testset "Differential fuzz: SparseArrays" begin
    include(joinpath(@__DIR__, "fuzz", "sparse_diff.jl"))
    run_sparse_tests()
end

# ForwardDiff (first SciML library) — forward-mode autodiff: derivative/gradient/
# jacobian, each compared wasm-vs-native against the real ForwardDiff.
@testset "Differential fuzz: ForwardDiff" begin
    include(joinpath(@__DIR__, "fuzz", "forwarddiff_diff.jl"))
    run_forwarddiff_tests()
end

# StaticArrays — the SVector surface (construction/getindex/destructure/arith/
# broadcast), SArray laid out by its NTuple field + the construct_type overlay.
@testset "Differential fuzz: StaticArrays" begin
    include(joinpath(@__DIR__, "fuzz", "staticarrays_diff.jl"))
    run_staticarrays_tests()
end

# SimpleDiffEq (+ SciMLBase/DiffEqBase) — fixed-step ODE solvers: solve real ODEs
# in wasm via every solver (Euler/RK4/Tsit5/LoopEuler/LoopRK4) for scalar, Vector
# and SVector states, compared wasm-vs-native against the real SimpleDiffEq.
@testset "Differential fuzz: SimpleDiffEq" begin
    include(joinpath(@__DIR__, "fuzz", "simplediffeq_diff.jl"))
    run_simplediffeq_tests()
end

# The apparatus's own checks, each in its own process (each loads the fuzz modules itself):
# the oracle bridge round-trips return values (test_bridge.jl) and arguments with their
# mutations (test_bridge_args.jl); the statement generator emits well-typed programs
# (test_statements.jl). A broken oracle would pass every differential above.
@testset "Differential fuzz: apparatus self-checks" begin
    for t in ("test_bridge.jl", "test_bridge_args.jl", "test_statements.jl")
        cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) $(joinpath(@__DIR__, "fuzz", t))`
        @test success(pipeline(cmd; stdout=stdout, stderr=stderr))
    end
end

# README.md's per-stdlib support percentages are the ones stdlib_coverage.jl measures.
@testset "Differential fuzz: README stdlib support" begin
    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) $(joinpath(@__DIR__, "fuzz", "stdlib_coverage.jl")) check`
    @test success(pipeline(cmd; stdout=stdout, stderr=stderr))
end
