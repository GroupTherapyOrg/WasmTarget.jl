# ============================================================================
# Differential fuzz of ForwardDiff.jl — forward-mode autodiff (first SciML lib).
# ============================================================================
# Ships EXACT derivatives in wasm: `derivative` compiles straight from the real
# impl; `gradient`/`jacobian` are overlaid in ext/WasmTargetForwardDiffExt.jl to
# reuse the single-partial `Dual` seed (the path `derivative` already compiles),
# one input direction at a time — bit-identical to native's Partials{N} vector
# mode (forward-mode partials never cross slots). The whole value path is
# unlocked by the Dual/Partials carve-out in is_struct_type (src/codegen/structs.jl).
#
# Verified dense-in / dense-out (the differentiated function lives INSIDE the
# wrapper, since the bridge can't marshal a function argument) — derivative takes
# a Float64 → Float64, gradient a Vector{Float64} → Vector{Float64}, jacobian a
# Vector{Float64} → Matrix{Float64}. Every wrapper is compared wasm-vs-native
# against the REAL ForwardDiff, same oracle as core. Loaded by fuzz_suite.jl
# AFTER fuzz/run.jl. Entry: run_forwarddiff_tests(). Exports FORWARDDIFF_VERIFIED.

using ForwardDiff
using LinearAlgebra
using Random
using Test

const _FD_B = WasmTarget.Bridge

function _fd_diff(fn, argTs::Tuple, inputs::Vector, rettype)
    res = bridge_run_args(fn, argTs, inputs; rettype = rettype)
    res isa Vector || return false
    rdesc = _FD_B.descriptor(rettype)[1]
    for (i, r) in enumerate(res)
        a = inputs[i]
        nat = try (true, fn(deepcopy.(a)...)) catch; (false, nothing) end
        ok = r[1] === :ok ? (nat[1] && _FD_B.tree_matches(rdesc, nat[2], r[2])) : !nat[1]
        ok || return false
    end
    return true
end

# ForwardDiff public AD surface this file differentially verifies (for the
# coverage report). The number type + accessors (Dual/value/partials) are
# exercised transitively by every derivative below.
const FORWARDDIFF_VERIFIED = Set{Symbol}([
    :derivative, :gradient, :jacobian, :hessian,
    :derivative!, :gradient!, :jacobian!, :hessian!])

# ----- scalar derivative f: R → R (wrapper closes over the function) ----------
_fd_d_poly(x::Float64)  = ForwardDiff.derivative(t -> t^3 - 2t^2 + 3t - 1, x)
_fd_d_trig(x::Float64)  = ForwardDiff.derivative(t -> sin(t) * exp(-t), x)
_fd_d_rat(x::Float64)   = ForwardDiff.derivative(t -> 1.0 / (1.0 + t^2), x)        # Witch of Agnesi
_fd_d_tanh(x::Float64)  = ForwardDiff.derivative(t -> tanh(2t) + log(1.0 + t^2), x)
_fd_d_mix(x::Float64)   = ForwardDiff.derivative(t -> t * cos(t) + exp(t / 3), x)

# ----- gradient ∇f: Rⁿ → Rⁿ ---------------------------------------------------
_fd_g_quad(u::Vector{Float64}) = ForwardDiff.gradient(v -> v[1]^2 + v[2]^2 + v[1]*v[2], u)
_fd_g_trig(u::Vector{Float64}) = ForwardDiff.gradient(v -> sin(v[1]) * cos(v[2]) + exp(v[1]), u)
# Rosenbrock — the canonical optimization test function (its gradient drives every
# gradient-descent / BFGS demo).
_fd_g_rosen(u::Vector{Float64}) = ForwardDiff.gradient(v -> (1.0 - v[1])^2 + 100.0*(v[2] - v[1]^2)^2, u)
_fd_g_sumsq(u::Vector{Float64}) = ForwardDiff.gradient(v -> sum(v.^2), u)           # ∇‖v‖² = 2v
_fd_g_logistic(u::Vector{Float64}) = ForwardDiff.gradient(v -> log(1.0 + exp(v[1]*v[2] + v[3])), u)

# ----- jacobian Jf: Rⁿ → Rᵐˣⁿ (f returns a VECTOR; literal `[…]` exercises the
#       array-of-Dual path the carve-out fixes) ---------------------------------
_fd_j_bilin(u::Vector{Float64}) = ForwardDiff.jacobian(v -> [v[1]*v[2], v[1] + v[2]], u)
_fd_j_nlsys(u::Vector{Float64}) = ForwardDiff.jacobian(v -> [v[1]^2 + v[2]^2 - 1.0, v[1] - v[2]], u)  # Newton system
_fd_j_trig(u::Vector{Float64})  = ForwardDiff.jacobian(v -> [sin(v[1]), cos(v[2]), v[1]*v[2]], u)
_fd_j_polar(u::Vector{Float64}) = ForwardDiff.jacobian(v -> [v[1]*cos(v[2]), v[1]*sin(v[2])], u)      # polar→cartesian

# ----- compositions: the OUTPUT of one AD op feeds the next / a reduction,
#       proving the results are real arrays you can keep computing with ---------
_fd_c_gradnorm(u::Vector{Float64}) = norm(ForwardDiff.gradient(v -> v[1]^2 + v[2]^3, u))   # ‖∇f‖
_fd_c_gradsum(u::Vector{Float64})  = sum(ForwardDiff.gradient(v -> sin(v[1]) + v[2]^2, u))
_fd_c_jacsum(u::Vector{Float64})   = sum(ForwardDiff.jacobian(v -> [v[1]*v[2], v[1]^2], u))
_fd_c_jacvec(u::Vector{Float64})   = ForwardDiff.jacobian(v -> [v[1]*v[2], v[1]+v[2]], u) * u  # J·x
# gradient of a function built from a NAMED helper — proves AD threads through a
# user call boundary, not just an inline lambda
_fd_helper(v) = v[1]^2 * v[2] + sin(v[1] * v[2])
_fd_c_gradhelp(u::Vector{Float64}) = ForwardDiff.gradient(_fd_helper, u)
# Newton step direction J \ F via a hand 2×2 solve — gradient/jacobian feeding a
# concrete downstream numeric computation (what a root-finder actually does)
function _fd_c_newton(u::Vector{Float64})
    F(v) = [v[1]^2 + v[2]^2 - 4.0, v[1]*v[2] - 1.0]
    J = ForwardDiff.jacobian(F, u)
    f = F(u)
    det = J[1,1]*J[2,2] - J[1,2]*J[2,1]
    # u - J⁻¹ f  (2×2 closed-form inverse)
    s1 = (J[2,2]*f[1] - J[1,2]*f[2]) / det
    s2 = (-J[2,1]*f[1] + J[1,1]*f[2]) / det
    return [u[1] - s1, u[2] - s2]
end

# ----- hessian Hf: Rⁿ → Rⁿˣⁿ (forward-over-forward, ext overlay) --------------
_fd_h_quad(u::Vector{Float64})  = ForwardDiff.hessian(v -> v[1]^2*v[2] + sin(v[1]) + v[2]^3, u)
_fd_h_rosen(u::Vector{Float64}) = ForwardDiff.hessian(v -> (1.0 - v[1])^2 + 100.0*(v[2] - v[1]^2)^2, u)  # Newton's method uses this
_fd_h_prod(u::Vector{Float64})  = ForwardDiff.hessian(v -> exp(v[1]*v[2]) + v[1]^3, u)

# ----- in-place variants (write into a preallocated buffer; ext overlays) -----
_fd_b_grad(u::Vector{Float64})  = (o = similar(u); ForwardDiff.gradient!(o, v -> v[1]^2 + v[2]^3 + v[1]*v[2], u); o)
_fd_b_jac(u::Vector{Float64})   = (o = Matrix{Float64}(undef, 2, length(u)); ForwardDiff.jacobian!(o, v -> [v[1]*v[2], sin(v[1]) + v[2]], u); o)
_fd_b_hess(u::Vector{Float64})  = (o = Matrix{Float64}(undef, length(u), length(u)); ForwardDiff.hessian!(o, v -> v[1]^3 + v[1]*v[2]^2, u); o)
_fd_b_der(u::Vector{Float64})   = (o = Vector{Float64}(undef, 3); ForwardDiff.derivative!(o, t -> [t^2, sin(t), exp(t)], u[1]); o)  # f: R→R³

function run_forwarddiff_tests(; reps::Int = 40)
    FuzzHarness.NODE_OK || (@test_skip true; return)
    rng = MersenneTwister(0xF0D1)
    sc()  = [ (2rand(rng) - 1 + 0.05,) for _ in 1:reps ]                       # scalar inputs (avoid exact 0)
    v2()  = [ (Float64[2rand(rng) - 1, 2rand(rng) - 1],) for _ in 1:reps ]      # length-2 vectors
    v3()  = [ (Float64[2rand(rng) - 1, 2rand(rng) - 1, 2rand(rng) - 1],) for _ in 1:reps ]
    @testset "derivative (R→R)" begin
        @test _fd_diff(_fd_d_poly, (Float64,), sc(), Float64)
        @test _fd_diff(_fd_d_trig, (Float64,), sc(), Float64)
        @test _fd_diff(_fd_d_rat,  (Float64,), sc(), Float64)
        @test _fd_diff(_fd_d_tanh, (Float64,), sc(), Float64)
        @test _fd_diff(_fd_d_mix,  (Float64,), sc(), Float64)
    end
    @testset "gradient (Rⁿ→Rⁿ)" begin
        @test _fd_diff(_fd_g_quad,     (Vector{Float64},), v2(), Vector{Float64})
        @test _fd_diff(_fd_g_trig,     (Vector{Float64},), v2(), Vector{Float64})
        @test _fd_diff(_fd_g_rosen,    (Vector{Float64},), v2(), Vector{Float64})
        @test _fd_diff(_fd_g_sumsq,    (Vector{Float64},), v2(), Vector{Float64})
        @test _fd_diff(_fd_g_logistic, (Vector{Float64},), v3(), Vector{Float64})
    end
    @testset "jacobian (Rⁿ→Rᵐˣⁿ, literal vector output)" begin
        @test _fd_diff(_fd_j_bilin, (Vector{Float64},), v2(), Matrix{Float64})
        @test _fd_diff(_fd_j_nlsys, (Vector{Float64},), v2(), Matrix{Float64})
        @test _fd_diff(_fd_j_trig,  (Vector{Float64},), v2(), Matrix{Float64})
        @test _fd_diff(_fd_j_polar, (Vector{Float64},), v2(), Matrix{Float64})
    end
    @testset "hessian (Rⁿ→Rⁿˣⁿ, forward-over-forward)" begin
        @test _fd_diff(_fd_h_quad,  (Vector{Float64},), v2(), Matrix{Float64})
        @test _fd_diff(_fd_h_rosen, (Vector{Float64},), v2(), Matrix{Float64})
        @test _fd_diff(_fd_h_prod,  (Vector{Float64},), v2(), Matrix{Float64})
    end
    @testset "in-place variants (gradient!/jacobian!/hessian!/derivative!)" begin
        @test _fd_diff(_fd_b_grad, (Vector{Float64},), v2(), Vector{Float64})
        @test _fd_diff(_fd_b_jac,  (Vector{Float64},), v2(), Matrix{Float64})
        @test _fd_diff(_fd_b_hess, (Vector{Float64},), v2(), Matrix{Float64})
        @test _fd_diff(_fd_b_der,  (Vector{Float64},), v2(), Vector{Float64})
    end
    @testset "compositions (AD result feeds the next computation)" begin
        @test _fd_diff(_fd_c_gradnorm, (Vector{Float64},), v2(), Float64)
        @test _fd_diff(_fd_c_gradsum,  (Vector{Float64},), v2(), Float64)
        @test _fd_diff(_fd_c_jacsum,   (Vector{Float64},), v2(), Float64)
        @test _fd_diff(_fd_c_jacvec,   (Vector{Float64},), v2(), Vector{Float64})
        @test _fd_diff(_fd_c_gradhelp, (Vector{Float64},), v2(), Vector{Float64})
        @test _fd_diff(_fd_c_newton,   (Vector{Float64},), v2(), Vector{Float64})
    end
end
