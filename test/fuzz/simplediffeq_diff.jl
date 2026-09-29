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
    if !(res isa Vector)
        @error("SimpleDiffEq differential compile/run failure", function_name = string(nameof(fn)),
               argument_types = argTs, return_type = rettype, result = res)
        return false
    end
    rdesc = _SDE_B.descriptor(rettype)[1]
    for (i, r) in enumerate(res)
        a = inputs[i]
        nat = try (true, fn(deepcopy.(a)...)) catch; (false, nothing) end
        ok = r[1] === :ok ? (nat[1] && _SDE_B.tree_matches(rdesc, nat[2], r[2];
                                                          nonportable = get(_SDE_NONPORTABLE, fn, nothing))) : !nat[1]
        if !ok
            @error("SimpleDiffEq differential mismatch", function_name = string(nameof(fn)),
                   input = a, native = nat, wasm = r)
            return false
        end
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
# parameterized rhs — coefficients fed through `p` (NTuple), not closure capture:
_sde_pdecay(u, p, t)   = -p[1] * u                            # scalar  u' = -k·u
_sde_plorenz(u, p, t)  = SVector{3,Float64}(p[1]*(u[2]-u[1]), # SVector Lorenz (σ,ρ,β = p)
                                            u[1]*(p[2]-u[3])-u[2],
                                            u[1]*u[2]-p[3]*u[3])

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
    # parameterized (4-arg ODEProblem, p::NTuple): scalar decay rate + Lorenz σ-sweep.
    @eval $(Symbol("_sde_pdecay_", S))(k::Float64) =
        solve(ODEProblem(_sde_pdecay, 1.0, (0.0, 1.0), (k,)), $S(); dt = 0.05).u[end]
    @eval $(Symbol("_sde_plorenz_", S))(sig::Float64) =
        sum(solve(ODEProblem(_sde_plorenz, SVector{3,Float64}(1.0, 1.0, 1.0), (0.0, 1.0),
                             (sig, 28.0, 2.6666666666666665)), $S(); dt = 0.01).u[end])
end

# The cases whose native value's last bits are not Julia's portable answer: every one. Each
# solver's step is `@muladd` (euler.jl:173, rk4.jl:160, tsit5.jl:303, loopeuler.jl:55,
# looprk4.jl:55), and Julia leaves a muladd_float free to round once or twice: LLVM contracts
# it or not instruction by instruction, per target. The module rounds once, as
# Base.fma_emulated. Native differed from it in the last bits in single cases on arm64 and
# x86_64 hosts with FMA, and in 34 of 40 cases on an x86_64 host without FMA. Each entry is
# checked, not believed: run_simplediffeq_tests asserts that its solver's step method calls
# muladd (_sde_step_calls_muladd).
const _SDE_CASES = (:_sde_decay_, :_sde_logistic_, :_sde_osc_, :_sde_lv_, :_sde_pend_,
                    :_sde_oscS_, :_sde_pdecay_, :_sde_plorenz_)
const _SDE_NONPORTABLE = Dict{Function,String}(
    getfield(@__MODULE__, Symbol(c, S)) => "muladd SimpleDiffEq $(S) step!" for S in _SDE_SOLVERS for c in _SDE_CASES
)

# The step each solver runs, where its reason says the muladd is: SimpleEuler, SimpleRK4 and
# SimpleTsit5 step an integrator (DiffEqBase.step!); LoopEuler and LoopRK4 loop inside __solve.
const _SDE_STEP_METHOD = Dict{Symbol,Tuple{Function,String}}(
    :SimpleEuler => (SimpleDiffEq.DiffEqBase.step!, "euler.jl"),
    :SimpleRK4   => (SimpleDiffEq.DiffEqBase.step!, "rk4.jl"),
    :SimpleTsit5 => (SimpleDiffEq.DiffEqBase.step!, "tsit5.jl"),
    :LoopEuler   => (SimpleDiffEq.SciMLBase.__solve, "loopeuler.jl"),
    :LoopRK4     => (SimpleDiffEq.SciMLBase.__solve, "looprk4.jl"))

# whether the solver's step, as SimpleDiffEq defines it in its file, calls muladd (the claim
# each _SDE_NONPORTABLE entry makes). Native solve reaches the step by dynamic dispatch, so no
# typed IR walk from the case can; the method's lowered code is where @muladd put the calls.
function _sde_step_calls_muladd(S::Symbol)::Bool
    f, file = _SDE_STEP_METHOD[S]
    ismuladd(g) = g === Base.muladd || (g isa GlobalRef && g.name === :muladd)
    calls(x) = x isa Expr && ((x.head === :call && ismuladd(x.args[1])) || any(calls, x.args))
    # a keyword method's body is its generated `#f#N` function, defined in the same file
    fs = Any[f; [getfield(SimpleDiffEq, n) for n in names(SimpleDiffEq; all = true)
                 if isdefined(SimpleDiffEq, n) && getfield(SimpleDiffEq, n) isa Function]]
    for g in fs, m in methods(g)
        (m.module === SimpleDiffEq && basename(string(m.file)) == file) || continue
        any(calls, Base.uncompressed_ast(m).code) && return true
    end
    return false
end

function run_simplediffeq_tests(; reps::Int = 30)
    @testset "every solver's step calls muladd (the nonportable reason)" begin
        for S in _SDE_SOLVERS
            calls = _sde_step_calls_muladd(S)
            calls || @error "a SimpleDiffEq solver marked nonportable has no muladd in its step" S
            @test calls
        end
    end
    rng = MersenneTwister(0x5DE0)
    ic() = [ (0.5 + rand(rng),) for _ in 1:reps ]   # initial conditions in (0.5, 1.5)
    for S in _SDE_SOLVERS
        @testset "$S — scalar / Vector-state / SVector-state ODEs" begin
            # scalar states → Float64
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_decay_", S)),    (Float64,), ic(), Float64)
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_logistic_", S)), (Float64,), ic(), Float64)
            # Vector states → Vector{Float64}, every solver on both Julias. (On 1.13.0 SimpleRK4's
            # and SimpleTsit5's `__solve` had a control region the stackifier rejected; 1.13.1's IR
            # compiles and runs bit-exact.)
            for sys in (:_sde_osc_, :_sde_lv_, :_sde_pend_)
                @test _sde_diff(getfield(@__MODULE__, Symbol(sys, S)), (Float64,), ic(), Vector{Float64})
            end
            # SVector state → Float64 (reduction)
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_oscS_", S)), (Float64,), ic(), Float64)
            # parameterized (4-arg ODEProblem, p::NTuple) — scalar + SVector-Lorenz
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_pdecay_", S)),  (Float64,), ic(), Float64)
            @test _sde_diff(getfield(@__MODULE__, Symbol("_sde_plorenz_", S)), (Float64,),
                            [ (8.0 + rand(rng) * 6.0,) for _ in 1:reps ], Float64)   # σ ∈ (8,14)
        end
    end
end
