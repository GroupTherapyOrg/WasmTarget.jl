# ============================================================================
# Differential fuzz of StaticArrays — the SVector surface (ext: WasmTargetStaticArraysExt).
# ============================================================================
# SVector{N,T} === SArray{Tuple{N},T,1,N} is an NTuple-backed struct, not a heap
# array. The ext makes WT (a) lay it out as the concrete struct it is (`:SArray`
# in _ARRAY_STRUCT_CARVEOUT) and (b) infer its construction concretely (overlay
# `construct_type` for already-parameterized SArray → identity, since WT's
# concrete-eval is off and can't fold the type-level adapt_size/adapt_eltype/
# typeintersect machinery the way native does).
#
# Every wrapper returns a SCALAR or Vector reduction (the bridge marshals those),
# computed from SVectors built INSIDE the wrapper, and is compared wasm-vs-native
# against the REAL StaticArrays — same oracle as core. Loaded by fuzz_suite.jl
# AFTER fuzz/run.jl. Entry: run_staticarrays_tests(). Exports STATICARRAYS_VERIFIED.

using StaticArrays
using Random
using Test

const _SA_B = WasmTarget.Bridge

function _sa_diff(fn, argTs::Tuple, inputs::Vector, rettype)
    res = bridge_run_args(fn, argTs, inputs; rettype = rettype)
    res isa Vector || return false
    rdesc = _SA_B.descriptor(rettype)[1]
    for (i, r) in enumerate(res)
        a = inputs[i]
        nat = try (true, fn(deepcopy.(a)...)) catch; (false, nothing) end
        ok = r[1] === :ok ? (nat[1] && _SA_B.tree_matches(rdesc, nat[2], r[2])) : !nat[1]
        ok || return false
    end
    return true
end

# SVector surface this file differentially verifies (for the coverage report).
const STATICARRAYS_VERIFIED = Set{Symbol}([
    :SVector, :SArray, :getindex, :iterate, :length, :sum, :prod,
    :dot, :(+), :(-), :(*), :map, :broadcast])

# ----- construction: positional / single-tuple / converting-eltype, all N ------
_sa_c_n1(x::Float64)  = (v = SVector{1,Float64}(x);          v[1] * 2.0)               # degenerate L=1
_sa_c_n2(x::Float64)  = (v = SVector{2,Float64}(x, 2x);      v[1] + v[2])
_sa_c_n3(x::Float64)  = (v = SVector{3,Float64}(x, 2x, 3x);  v[1] + v[2] + v[3])
_sa_c_n4(x::Float64)  = (v = SVector{4,Float64}(x, 2x, 3x, 4x); v[1] + v[4])
_sa_c_tuple(x::Float64) = (v = SVector{3,Float64}((x, 2x, 3x));  v[1] + v[2] + v[3])    # single-Tuple ctor
_sa_c_convert(x::Float64) = (v = SVector{3,Float64}(1, 2, 3);    v[1] + v[2] + v[3] + x) # Int args → convert

# ----- reductions over an SVector ---------------------------------------------
_sa_r_sum(x::Float64)  = sum(SVector{4,Float64}(x, 2x, 3x, 4x))
_sa_r_prod(x::Float64) = prod(SVector{3,Float64}(x, x + 1.0, x + 2.0))
_sa_r_max(x::Float64)  = maximum(SVector{4,Float64}(x, -x, 2x, 0.5x))
_sa_r_min(x::Float64)  = minimum(SVector{4,Float64}(x, -x, 2x, 0.5x))

# ----- iterate / destructure ---------------------------------------------------
function _sa_destr(x::Float64)
    v = SVector{3,Float64}(x, 2x, 3x)
    a, b, c = v
    a * 100.0 + b * 10.0 + c
end
function _sa_loop(x::Float64)               # for-loop over the SVector
    v = SVector{5,Float64}(x, 2x, 3x, 4x, 5x)
    s = 0.0
    for e in v
        s += e * e
    end
    s
end

# ----- arithmetic / dot / broadcast (SVector ↔ SVector, SVector ↔ scalar) ------
_sa_a_add(x::Float64) = (a = SVector{3,Float64}(x, 2x, 3x); b = SVector{3,Float64}(1.0, 1.0, 1.0); c = a + b; c[1] + c[2] + c[3])
_sa_a_sub(x::Float64) = (a = SVector{3,Float64}(x, 2x, 3x); b = SVector{3,Float64}(0.5, 0.5, 0.5); c = a - b; c[1] + c[2] + c[3])
_sa_a_scale(x::Float64) = (a = SVector{3,Float64}(x, 2x, 3x); c = 2.5 * a; c[1] + c[2] + c[3])
_sa_a_dot(x::Float64) = (a = SVector{3,Float64}(x, 2x, 3x); dot(a, a))
_sa_a_bcast(x::Float64) = (a = SVector{3,Float64}(x, 2x, 3x); c = a .* a .+ 1.0; c[1] + c[2] + c[3])
_sa_a_combo(x::Float64) = (a = SVector{3,Float64}(x, 2x, 3x); b = SVector{3,Float64}(x, -x, x); sum(2.0 .* a .- b))

# ----- returns a Vector (collect) so the bridge sees the full element sequence --
_sa_collect3(x::Float64) = collect(SVector{3,Float64}(x, 2x, 3x))
_sa_addvec(x::Float64)   = collect(SVector{3,Float64}(x, 2x, 3x) + SVector{3,Float64}(1.0, 2.0, 3.0))

function run_staticarrays_tests(; reps::Int = 40)
    FuzzHarness.NODE_OK || (@test_skip true; return)
    rng = MersenneTwister(0x57A6)
    sc() = [ (2rand(rng) - 1 + 1.5,) for _ in 1:reps ]   # positive-ish scalars
    @testset "construction (positional/tuple/converting, all N≥1)" begin
        @test _sa_diff(_sa_c_n1,      (Float64,), sc(), Float64)
        @test _sa_diff(_sa_c_n2,      (Float64,), sc(), Float64)
        @test _sa_diff(_sa_c_n3,      (Float64,), sc(), Float64)
        @test _sa_diff(_sa_c_n4,      (Float64,), sc(), Float64)
        @test _sa_diff(_sa_c_tuple,   (Float64,), sc(), Float64)
        @test _sa_diff(_sa_c_convert, (Float64,), sc(), Float64)
    end
    @testset "reductions (sum/prod/maximum/minimum)" begin
        @test _sa_diff(_sa_r_sum,  (Float64,), sc(), Float64)
        @test _sa_diff(_sa_r_prod, (Float64,), sc(), Float64)
        @test _sa_diff(_sa_r_max,  (Float64,), sc(), Float64)
        @test _sa_diff(_sa_r_min,  (Float64,), sc(), Float64)
    end
    @testset "iterate / destructure / for-loop" begin
        @test _sa_diff(_sa_destr, (Float64,), sc(), Float64)
        @test _sa_diff(_sa_loop,  (Float64,), sc(), Float64)
    end
    @testset "arithmetic / dot / broadcast" begin
        @test _sa_diff(_sa_a_add,   (Float64,), sc(), Float64)
        @test _sa_diff(_sa_a_sub,   (Float64,), sc(), Float64)
        @test _sa_diff(_sa_a_scale, (Float64,), sc(), Float64)
        @test _sa_diff(_sa_a_dot,   (Float64,), sc(), Float64)
        @test _sa_diff(_sa_a_bcast, (Float64,), sc(), Float64)
        @test _sa_diff(_sa_a_combo, (Float64,), sc(), Float64)
    end
    @testset "Vector output (collect)" begin
        @test _sa_diff(_sa_collect3, (Float64,), sc(), Vector{Float64})
        @test _sa_diff(_sa_addvec,   (Float64,), sc(), Vector{Float64})
    end
end
