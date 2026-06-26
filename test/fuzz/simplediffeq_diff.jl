# ============================================================================
# Differential fuzz of SimpleDiffEq — fixed-step ODE solvers (ext: WasmTargetSimpleDiffEqExt).
# ============================================================================
# Solves real ODEs inside a frozen wasm module — exponential decay, harmonic
# oscillator, Lotka–Volterra, nonlinear pendulum — bit/tolerance-identical to
# native, no host, no Julia runtime. The compiler wall is the SciMLBase ABSTRACTION
# the user touches (ODEProblem/ODEFunction construction + solve dispatch), built on
# runtime type-level machinery WT can't lower; three levers clear it (see
# ext/WasmTargetSimpleDiffEqExt.jl + the type-level concrete-eval fold in
# src/codegen/interpreter.jl). SimpleTsit5's Butcher tableau lives in SVector caches,
# so this also exercises ext/WasmTargetStaticArraysExt.
#
# The whole solve runs INSIDE each wrapper (the bridge can't marshal a function
# argument). u0 is driven by the Float64 input so every rep is a distinct ODE; the
# wrapper returns the final state (scalar / Vector) or a reduction of it. Compared
# wasm-vs-native against the REAL SimpleDiffEq, same oracle as core. Every fixed-step
# solver — SimpleEuler, SimpleRK4, SimpleTsit5, LoopEuler, LoopRK4 — is verified for
# scalar, Vector-state AND SVector-state ODEs (nothing dropped). Loaded by
# fuzz_suite.jl AFTER fuzz/run.jl. Entry: run_simplediffeq_tests().
# Exports SIMPLEDIFFEQ_VERIFIED.

using SimpleDiffEq
using SciMLBase
using DiffEqBase
using StaticArrays
using Random
using Test

const _SDE_B = WasmTarget.Bridge

function _sde_diff(fn, argTs::Tuple, inputs::Vector, rettype)
    res = bridge_run_args(fn, argTs, inputs; rettype = rettype)
    res isa Vector || return false
    rdesc = _SDE_B.descriptor(rettype)[1]
    for (i, r) in enumerate(res)
        a = inputs[i]
        nat = try (true, fn(deepcopy.(a)...)) catch; (false, nothing) end
        ok = r[1] === :ok ? (nat[1] && _SDE_B.tree_matches(rdesc, nat[2], r[2])) : !nat[1]
        ok || return false
    end
    return true
end

# SciMLBase / SimpleDiffEq surface this file differentially verifies.
const SIMPLEDIFFEQ_VERIFIED = Set{Symbol}([
    :solve, :ODEProblem, :ODEFunction, :__solve, :__init, :step!,
    :SimpleEuler, :SimpleRK4, :SimpleTsit5, :LoopEuler, :LoopRK4])

# The five fixed-step solvers the ext supports.
const _SDE_SOLVERS = (:SimpleEuler, :SimpleRK4, :SimpleTsit5, :LoopEuler, :LoopRK4)

# ----- ODE right-hand sides (out-of-place), defined at top level so they lower --
_sde_decay(u, p, t)    = -u                                   # scalar  u' = -u
_sde_logistic(u, p, t) = u * (1.0 - u)                        # scalar  logistic growth
_sde_osc(u, p, t)      = [-u[2], u[1]]                        # vector  harmonic oscillator (rotation)
_sde_lv(u, p, t)       = [1.5u[1] - u[1]*u[2], u[1]*u[2] - 3.0u[2]]   # Lotka–Volterra predator–prey
_sde_pend(u, p, t)     = [u[2], -sin(u[1])]                   # vector  nonlinear pendulum
_sde_oscS(u, p, t)     = SVector{2,Float64}(-u[2], u[1])      # SVector-state harmonic oscillator

# ----- generate a wrapper per (ODE, solver): solve INSIDE, return final state ---
# Short, bounded, non-chaotic integrations keep the @muladd/FMA ULP drift inside
# the tolerance oracle while still exercising the full step! loop.
for S in _SDE_SOLVERS
    @eval $(Symbol("_sde_decay_", S))(u0::Float64) =
        solve(ODEProblem(_sde_decay, u0, (0.0, 1.0)), $S(); dt = 0.05).u[end]
    @eval $(Symbol("_sde_logistic_", S))(u0::Float64) =
        solve(ODEProblem(_sde_logistic, u0, (0.0, 1.0)), $S(); dt = 0.05).u[end]
    @eval $(Symbol("_sde_osc_", S))(a::Float64) =
        solve(ODEProblem(_sde_osc, [a, 0.0], (0.0, 1.0)), $S(); dt = 0.05).u[end]
    @eval $(Symbol("_sde_lv_", S))(a::Float64) =
        solve(ODEProblem(_sde_lv, [a, 1.0], (0.0, 1.0)), $S(); dt = 0.05).u[end]
    @eval $(Symbol("_sde_pend_", S))(a::Float64) =
        solve(ODEProblem(_sde_pend, [a, 0.0], (0.0, 1.0)), $S(); dt = 0.05).u[end]
    # SVector-state: return a scalar reduction of the final SVector state.
    @eval $(Symbol("_sde_oscS_", S))(a::Float64) =
        sum(solve(ODEProblem(_sde_oscS, SVector{2,Float64}(a, 0.0), (0.0, 1.0)), $S(); dt = 0.05).u[end])
end

function run_simplediffeq_tests(; reps::Int = 30)
    FuzzHarness.NODE_OK || (@test_skip true; return)
    rng = MersenneTwister(0x5DE0)
    ic() = [ (0.5 + rand(rng),) for _ in 1:reps ]   # initial conditions in (0.5, 1.5)
    for S in _SDE_SOLVERS
        @testset "$S — scalar / Vector-state / SVector-state ODEs" begin
            # scalar states → Float64
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_decay_", S)),    (Float64,), ic(), Float64)
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_logistic_", S)), (Float64,), ic(), Float64)
            # Vector states → Vector{Float64}
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_osc_", S)),  (Float64,), ic(), Vector{Float64})
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_lv_", S)),   (Float64,), ic(), Vector{Float64})
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_pend_", S)), (Float64,), ic(), Vector{Float64})
            # SVector state → Float64 (reduction)
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_oscS_", S)), (Float64,), ic(), Float64)
        end
    end
end
