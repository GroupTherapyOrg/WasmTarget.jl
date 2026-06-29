# ============================================================================
# Differential fuzz of Statistics in-place ops (mean!/median!/quantile!).
# ============================================================================
# The non-! Statistics surface is fuzzed by the catalogue (mod=:stats); the
# in-place variants mutate a buffer (median!/quantile! sort the vector; mean!
# reduces a matrix into a vector) — verified HERE by direct differential sweeps.
# Loaded by fuzz_suite.jl AFTER fuzz/run.jl. Entry: run_stats_tests().

using Statistics
using Random
using Test

const _ST_B = WasmTarget.Bridge
const STATS_VERIFIED = Set{Symbol}([:mean!, :median!, :quantile!, :cor])

function _st_diff(fn, argTs::Tuple, inputs::Vector, rettype)
    res = bridge_run_args(fn, argTs, inputs; rettype = rettype)
    res isa Vector || return false
    rdesc = _ST_B.descriptor(rettype)[1]
    for (i, r) in enumerate(res)
        a = inputs[i]
        nat = try (true, fn(deepcopy.(a)...)) catch; (false, nothing) end
        ok = r[1] === :ok ? (nat[1] && _ST_B.tree_matches(rdesc, nat[2], r[2])) : !nat[1]
        ok || return false
    end
    return true
end

_st_rv(rng, n) = Float64[2rand(rng) - 1 for _ in 1:n]
_st_rm(rng, r, c) = Float64[2rand(rng) - 1 for _ in 1:r, _ in 1:c]
_st_medb(v)    = median!(v)
_st_quab(v, p) = quantile!(v, p)
_st_meanb(r, A) = mean!(r, A)
# cor exercises the type-level concrete-eval fold (src/codegen/interpreter.jl):
# its result type is `one(float(nonmissingtype(eltype)))` — a pure type-level
# chain that WT could not lower until the fold. 1-arg autocorrelation = 1.0 hits
# the chain directly; 2-arg uses the corm reroute (Statistics ext) for the value.
_st_cor1(v)    = cor(v)
_st_cor2(a, b) = cor(a, b)

function run_stats_tests(; reps::Int = 40)
    FuzzHarness.NODE_OK || (@test_skip true; return)
    rng = MersenneTwister(0x57A7)
    @testset "in-place median!/quantile!" begin
        @test _st_diff(_st_medb, (Vector{Float64},),
                       [ (_st_rv(rng, rand(rng, 3:9)),) for _ in 1:reps ], Float64)
        @test _st_diff(_st_quab, (Vector{Float64}, Float64),
                       [ (_st_rv(rng, rand(rng, 3:9)), rand(rng)) for _ in 1:reps ], Float64)
    end
    @testset "in-place mean! (row-means overlay)" begin
        @test _st_diff(_st_meanb, (Vector{Float64}, Matrix{Float64}),
                       [ (m = rand(rng, 2:4); n = rand(rng, 2:5); (zeros(m), _st_rm(rng, m, n))) for _ in 1:reps ],
                       Vector{Float64})
    end
    @testset "cor (type-level concrete-eval fold)" begin
        @test _st_diff(_st_cor1, (Vector{Float64},),
                       [ (_st_rv(rng, rand(rng, 3:7)),) for _ in 1:reps ], Float64)  # 1-arg → fold
        @test _st_diff(_st_cor2, (Vector{Float64}, Vector{Float64}),
                       [ (n = rand(rng, 3:7); (_st_rv(rng, n), _st_rv(rng, n))) for _ in 1:reps ], Float64)  # 2-arg
    end
end
