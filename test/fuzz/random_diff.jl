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
const RANDOM_VERIFIED = Set{Symbol}([:rand, :randn, :randexp, :randperm, :randcycle, :shuffle, :Xoshiro])

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
end
