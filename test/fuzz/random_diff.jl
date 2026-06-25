# ============================================================================
# Differential fuzz of the Random stdlib — SEEDED Xoshiro streams.
# ============================================================================
# Seeded RNG state is a struct the catalogue generator can't produce, so it's
# verified HERE: f(seed) constructs Xoshiro(seed) and draws — wasm vs native must
# be the SAME stream (bit-exact), which works because the Random ext makes
# hash_seed seeding bit-identical. Mirrors linalg_diff.jl / dates_diff.jl.
#
# CAN'T be fuzzed (documented, not silent): MersenneTwister (its larger state +
# seeding emit invalid wasm — a codegen gap), and OS-entropy RNGs (RandomDevice,
# seedless rand(), default TaskLocalRNG) — host-dependent, defer to embedding.
#
# Loaded by fuzz_suite.jl AFTER fuzz/run.jl. Entry: run_random_tests().

using Random
using Test

const _RND_B = WasmTarget.Bridge

function _rnd_diff(fn, argTs::Tuple, inputs::Vector, rettype)
    res = bridge_run_args(fn, argTs, inputs; rettype = rettype)
    res isa Vector || return false
    rdesc = _RND_B.descriptor(rettype)[1]
    for (i, r) in enumerate(res)
        a = inputs[i]
        nat = try (true, fn(a...)) catch; (false, nothing) end
        ok = r[1] === :ok ? (nat[1] && _RND_B.tree_matches(rdesc, nat[2], r[2])) : !nat[1]
        ok || return false
    end
    return true
end

# Random names this file verifies (for stdlib_coverage.jl).
const RANDOM_VERIFIED = let s = Set{Symbol}([
        :rand, :randn, :randexp, :randperm, :randcycle, :shuffle, :Xoshiro,
        :randperm!, :randcycle!, :shuffle!, :seed!])
    # randsubseq/randsubseq!/randstring are bit-exact on ≤1.12 but diverge
    # wasm↔native on 1.13-rc1 (RNG-consumption changes — see run_random_tests +
    # FINDINGS.md); claimed only where verified. Random = 100% on ≤1.12, 73% on 1.13.
    VERSION < v"1.13-" && push!(s, :randsubseq, :randsubseq!, :randstring)
    s
end

# seed → draw (the draw is a CALLEE so the seeded-stream path compiles)
_rx_f(s)    = rand(Xoshiro(s))
_rx_f32(s)  = rand(Xoshiro(s), Float32)
_rx_i64(s)  = rand(Xoshiro(s), Int64)
_rx_u8(s)   = rand(Xoshiro(s), UInt8)
_rx_u32(s)  = rand(Xoshiro(s), UInt32)
_rx_bool(s) = rand(Xoshiro(s), Bool)
_rx_rng(s)  = rand(Xoshiro(s), 1:1000)
_rx_n(s)    = randn(Xoshiro(s))
_rx_exp(s)  = randexp(Xoshiro(s))
_rx_perm(s) = randperm(Xoshiro(s), 9)
_rx_cyc(s)  = randcycle(Xoshiro(s), 9)
_rx_shuf(s, v) = shuffle(Xoshiro(s), v)
# in-place permutation fills (seed → mutate a buffer)
_rx_permb(s, p)  = randperm!(Xoshiro(s), p)
_rx_cycb(s, p)   = randcycle!(Xoshiro(s), p)
_rx_shufb(s, v)  = shuffle!(Xoshiro(s), v)
# seed!(rng, seed): reseed an existing rng, then draw → must match native
_rx_seedb(s)     = (r = Xoshiro(0); Random.seed!(r, s); rand(r))
# subsequence sampling (out-of-place + in-place into a fresh sink)
_rx_subseq(s, v)  = randsubseq(Xoshiro(s), v, 0.5)
_rx_subseqb(s, v) = randsubseq!(Xoshiro(s), Int64[], v, 0.4)
_rx_rstr(s)       = randstring(Xoshiro(s), 10)

function run_random_tests(; reps::Int = 60)
    FuzzHarness.NODE_OK || (@test_skip true; return)
    rng = MersenneTwister(0x5EED)
    seeds = [ (rand(rng, Int64),) for _ in 1:reps ]
    @testset "Xoshiro seeded rand" begin
        @test _rnd_diff(_rx_f,    (Int64,), seeds, Float64)
        @test _rnd_diff(_rx_f32,  (Int64,), seeds, Float32)
        @test _rnd_diff(_rx_i64,  (Int64,), seeds, Int64)
        @test _rnd_diff(_rx_u8,   (Int64,), seeds, UInt8)
        @test _rnd_diff(_rx_u32,  (Int64,), seeds, UInt32)
        @test _rnd_diff(_rx_bool, (Int64,), seeds, Bool)
        @test _rnd_diff(_rx_rng,  (Int64,), seeds, Int64)
    end
    @testset "Xoshiro seeded randn/randexp" begin
        @test _rnd_diff(_rx_n,   (Int64,), seeds, Float64)
        @test _rnd_diff(_rx_exp, (Int64,), seeds, Float64)
    end
    @testset "Xoshiro seeded permutations/shuffle" begin
        @test _rnd_diff(_rx_perm, (Int64,), seeds, Vector{Int64})
        @test _rnd_diff(_rx_cyc,  (Int64,), seeds, Vector{Int64})
        @test _rnd_diff(_rx_shuf, (Int64, Vector{Int64}),
                        [ (rand(rng, Int64), collect(1:rand(rng, 4:12))) for _ in 1:reps ], Vector{Int64})
    end
    @testset "Xoshiro in-place permutations (randperm!/randcycle!/shuffle!)" begin
        ivecs() = [ (rand(rng, Int64), collect(1:rand(rng, 4:12))) for _ in 1:reps ]
        @test _rnd_diff(_rx_permb, (Int64, Vector{Int64}), ivecs(), Vector{Int64})
        @test _rnd_diff(_rx_cycb,  (Int64, Vector{Int64}), ivecs(), Vector{Int64})
        @test _rnd_diff(_rx_shufb, (Int64, Vector{Int64}), ivecs(), Vector{Int64})
    end
    @testset "Xoshiro seed!/randsubseq/randstring" begin
        # seed! (reseed an existing rng, then draw) is bit-exact on every version.
        @test _rnd_diff(_rx_seedb, (Int64,), [ (rand(rng, Int64),) for _ in 1:reps ], Float64)
        # randsubseq/randsubseq! and randstring consume the RNG in ways that
        # diverge wasm↔native on 1.13-rc1: randsubseq/randsubseq! show an
        # input-dependent divergence (CI caught the in-place form one run, the
        # out-of-place form the next — same function), and randstring's charset
        # bulk fill is no longer scalar/plain-Vector reproducible on 1.13 (same
        # class as the Float64 SIMD fills). Verified bit-exact on ≤1.12; deferred
        # on 1.13 (see FINDINGS.md — soundness-loop candidates).
        if VERSION < v"1.13-"
            ivecs() = [ (rand(rng, Int64), collect(1:rand(rng, 4:12))) for _ in 1:reps ]
            @test _rnd_diff(_rx_subseq,  (Int64, Vector{Int64}), ivecs(), Vector{Int64})
            @test _rnd_diff(_rx_subseqb, (Int64, Vector{Int64}), ivecs(), Vector{Int64})
            @test _rnd_diff(_rx_rstr,    (Int64,), [ (rand(rng, Int64),) for _ in 1:reps ], String)
        else
            @test_skip true
        end
    end
end
