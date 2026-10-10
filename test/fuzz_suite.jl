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

# WT_FUZZ_PART=i/N (dev/lanes.sh --lane fuzz --part i/N, one job of dev/gate.sh's matrix) runs
# part i of N: the families below are packed longest-first onto the least-loaded part by their
# seconds measured on ubuntu CI (Julia 1.12, gate run 37930172953, each family's testset time), as
# runtests.jl packs its phases, so the N parts together run every family exactly once. Unset:
# every family.
const _FUZZ_SECONDS = [
    "Differential fuzz (bounded)" => 156.4,
    "Differential fuzz: LinearAlgebra matrix" => 309.5,
    "Differential fuzz: Dates value layer" => 85.6,
    "Differential fuzz: Random seeded streams" => 74.0,
    "Differential fuzz: Statistics in-place" => 36.5,
    "Differential fuzz: SparseArrays" => 588.1,
    "Differential fuzz: ForwardDiff" => 125.9,
    "Differential fuzz: StaticArrays" => 67.4,
    "Differential fuzz: SimpleDiffEq" => 316.2,
    "Differential fuzz: apparatus self-checks" => 500.2,
    "Differential fuzz: README stdlib support" => 9.8,
]
const _FUZZ_PART = let s = get(ENV, "WT_FUZZ_PART", "")
    m = match(r"^([0-9]+)/([1-9][0-9]*)$", s)
    if isempty(s)
        (0, 1)
    elseif m === nothing || parse(Int, m[1]) >= parse(Int, m[2])
        error("WT_FUZZ_PART=$s: expected i/N with 0 <= i < N")
    else
        (parse(Int, m[1]), parse(Int, m[2]))
    end
end
const _FUZZ_MINE = let (i, n) = _FUZZ_PART, load = zeros(n), mine = Set{String}()
    for (name, secs) in sort(_FUZZ_SECONDS; by = p -> -last(p))
        local s = argmin(load)
        load[s] += secs
        s - 1 == i && push!(mine, name)
    end
    mine
end
# each family runs in the part it is packed onto; a family missing from the table, in none
function _fuzz_family(name::String)::Bool
    any(p -> first(p) == name, _FUZZ_SECONDS) || error("fuzz family \"$name\" has no measured seconds in _FUZZ_SECONDS")
    return name in _FUZZ_MINE
end
_FUZZ_PART[2] > 1 && println("fuzz part $(_FUZZ_PART[1])/$(_FUZZ_PART[2]): ", join(sort!(collect(_FUZZ_MINE)), "; "))

# the bridge modules every family below uses
include(joinpath(@__DIR__, "fuzz", "run.jl"))

_fuzz_family("Differential fuzz (bounded)") && @testset "Differential fuzz (bounded)" begin
    @test ci_fuzz_passes(; types = (Int64, Float64), depth = 2, max_examples = 30, seed = 0xCD)
end

# LinearAlgebra MATRIX surface — verified by direct differential sweeps (the
# generator does Vector, not Matrix). run.jl above already loaded the bridge
# modules into this scope.
# Named "Differential fuzz: …" so runtests.jl's fuzz-log echo (which greps for
# "Differential fuzz") surfaces its Pass/Total summary line.
_fuzz_family("Differential fuzz: LinearAlgebra matrix") && @testset "Differential fuzz: LinearAlgebra matrix" begin
    include(joinpath(@__DIR__, "fuzz", "linalg_diff.jl"))
    run_linalg_matrix_tests()
end

# Dates value layer — Date/DateTime values the catalogue generator can't produce.
_fuzz_family("Differential fuzz: Dates value layer") && @testset "Differential fuzz: Dates value layer" begin
    include(joinpath(@__DIR__, "fuzz", "dates_diff.jl"))
    run_dates_tests()
end

# Random — seeded Xoshiro streams (RNG state the catalogue can't produce).
_fuzz_family("Differential fuzz: Random seeded streams") && @testset "Differential fuzz: Random seeded streams" begin
    include(joinpath(@__DIR__, "fuzz", "random_diff.jl"))
    run_random_tests()
end

# Statistics in-place ops (mean!/median!/quantile!).
_fuzz_family("Differential fuzz: Statistics in-place") && @testset "Differential fuzz: Statistics in-place" begin
    include(joinpath(@__DIR__, "fuzz", "stats_diff.jl"))
    run_stats_tests()
end

# SparseArrays foundation — sparse construction + read/reduce/matvec.
_fuzz_family("Differential fuzz: SparseArrays") && @testset "Differential fuzz: SparseArrays" begin
    include(joinpath(@__DIR__, "fuzz", "sparse_diff.jl"))
    run_sparse_tests()
end

# ForwardDiff (first SciML library) — forward-mode autodiff: derivative/gradient/
# jacobian, each compared wasm-vs-native against the real ForwardDiff.
_fuzz_family("Differential fuzz: ForwardDiff") && @testset "Differential fuzz: ForwardDiff" begin
    include(joinpath(@__DIR__, "fuzz", "forwarddiff_diff.jl"))
    run_forwarddiff_tests()
end

# StaticArrays — the SVector surface (construction/getindex/destructure/arith/
# broadcast), SArray laid out by its NTuple field + the construct_type overlay.
_fuzz_family("Differential fuzz: StaticArrays") && @testset "Differential fuzz: StaticArrays" begin
    include(joinpath(@__DIR__, "fuzz", "staticarrays_diff.jl"))
    run_staticarrays_tests()
end

# SimpleDiffEq (+ SciMLBase/DiffEqBase) — fixed-step ODE solvers: solve real ODEs
# in wasm via every solver (Euler/RK4/Tsit5/LoopEuler/LoopRK4) for scalar, Vector
# and SVector states, compared wasm-vs-native against the real SimpleDiffEq.
_fuzz_family("Differential fuzz: SimpleDiffEq") && @testset "Differential fuzz: SimpleDiffEq" begin
    include(joinpath(@__DIR__, "fuzz", "simplediffeq_diff.jl"))
    run_simplediffeq_tests()
end

# The apparatus's own checks, each in its own process (each loads the fuzz modules itself):
# the oracle bridge round-trips return values (test_bridge.jl) and arguments with their
# mutations (test_bridge_args.jl); the statement generator emits well-typed programs
# (test_statements.jl). A broken oracle would pass every differential above.
_fuzz_family("Differential fuzz: apparatus self-checks") && @testset "Differential fuzz: apparatus self-checks" begin
    for t in ("test_bridge.jl", "test_bridge_args.jl", "test_statements.jl")
        cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) $(joinpath(@__DIR__, "fuzz", t))`
        @test success(pipeline(cmd; stdout=stdout, stderr=stderr))
    end
end

# README.md's per-stdlib support percentages are the ones stdlib_coverage.jl measures.
_fuzz_family("Differential fuzz: README stdlib support") && @testset "Differential fuzz: README stdlib support" begin
    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) $(joinpath(@__DIR__, "fuzz", "stdlib_coverage.jl")) check`
    @test success(pipeline(cmd; stdout=stdout, stderr=stderr))
end
