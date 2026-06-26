# WasmTargetSimpleDiffEqExt — SimpleDiffEq (+ SciMLBase) integration: the first
# TRUE SciML-org library. Solve ODEs in a frozen wasm module — Lorenz, pendulum,
# predator-prey — bit-identical to native, no host, no Julia runtime.
#
# SimpleDiffEq is the lightweight, "no-cruft" member of the DifferentialEquations
# family. Its fixed-step solvers (SimpleEuler/SimpleRK4/SimpleTsit5) are pure
# explicit Runge-Kutta — arithmetic + array ops WasmGC handles. The wall is the
# SciMLBase ABSTRACTION the user touches: ODEProblem/ODEFunction construction and
# the solve dispatch are built on runtime type-level machinery (apply_type,
# isinplace method-arity reflection, kwarg-Pairs eltype) that WT can't lower.
#
# Three levers (verified bit-identical — see test/fuzz/simplediffeq_diff.jl):
#
# (1) CORE FOLD (src/codegen/interpreter.jl): re-enables concrete-eval for a
#     curated whitelist of pure type-level fns (apply_type/sparams/eltype/
#     _compute_eltype/isinplace-type-param/...). Folds the type computations native
#     folds away but WT left as `dynamic` dispatch on Type values.
#
# (2) CONSTRUCTION OVERLAY: the outer `ODEProblem(f, u0, tspan)` runs `isinplace(f)`
#     on a RAW function — kwarg method-arity reflection the fold can't reach. Build
#     the ODEFunction CONCRETELY (no reflection) then `ODEProblem{false}(odef, …)`:
#     the inner ctor's `isinplace(odef::ODEFunction{false})` is just the type-param
#     `iip`, which the fold DOES handle. The explicit ODEFunction/ODEProblem are
#     byte-identical to native's.
#
# (3) SOLVE OVERLAY: the generic `solve` routes through DiffEqBase's
#     get_concrete_problem/solve_call, which builds a Pairs type from a RUNTIME
#     kwargs NamedTuple (unfoldable). Call `DiffEqBase.__solve` directly — the clean
#     integrator (time grid + step! loop + build_solution).
#
# Plus the `_ARRAY_STRUCT_CARVEOUT` registration: `ODESolution` is `<:AbstractArray`
# (an AbstractVectorOfArray), so WT's is_struct_type would give it the 2-field array
# layout and its `.u`/`.t` fields would be unreachable (dynamic getfield). Register
# the SciML solution/interpolation types to use their REAL fields (SparseArrays
# pattern).
module WasmTargetSimpleDiffEqExt

using WasmTarget
using SimpleDiffEq
using SciMLBase
using DiffEqBase
using LinearAlgebra
using Base.Experimental: @overlay

const WMT = WasmTarget.WASM_METHOD_TABLE
const SB = SciMLBase

# Fixed-step explicit solvers supported (adaptive SimpleATsit5 diverges — its
# error-control + interpolation are out of scope, like the LAPACK packed forms).
const _WT_SOLVERS = Union{SimpleEuler, SimpleRK4, SimpleTsit5, LoopEuler, LoopRK4}

function __init__()
    # SciML solution/interpolation types are <:AbstractArray but real structs —
    # register them so their fields (.u/.t/.interp/…) are reachable, not dynamic.
    push!(WasmTarget._ARRAY_STRUCT_CARVEOUT,
          :ODESolution, :LinearInterpolation, :DiffEqArray, :VectorOfArray)
end

# Concrete ODEFunction (out-of-place, AutoSpecialize) — bypass the reflection.
@inline function _wt_odefunc(f::F) where {F}
    SB.ODEFunction{false, SB.AutoSpecialize, F, LinearAlgebra.UniformScaling{Bool},
        Nothing, Nothing, Nothing, Nothing, Nothing, Nothing, Nothing, Nothing,
        Nothing, Nothing, Nothing, Nothing, typeof(SB.DEFAULT_OBSERVED),
        Nothing, Nothing, Nothing, Nothing}(
        f, LinearAlgebra.I, nothing, nothing, nothing, nothing, nothing, nothing,
        nothing, nothing, nothing, nothing, nothing, nothing, SB.DEFAULT_OBSERVED,
        nothing, nothing, nothing, nothing)
end

# (2) outer ODEProblem ctor → concrete construction (scalar or vector state).
@overlay WMT SB.ODEProblem(f::F, u0, tspan::Tuple{Float64, Float64}) where {F} =
    SB.ODEProblem{false}(_wt_odefunc(f), u0, tspan)

# (3) generic solve → __solve (bypass the kwarg-Pairs machinery).
@overlay WMT SB.solve(prob::SB.ODEProblem, alg::_WT_SOLVERS; dt, kw...) =
    DiffEqBase.__solve(prob, alg; dt = dt)

end # module
