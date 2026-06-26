# WasmTargetForwardDiffExt — ForwardDiff.jl integration (first SciML library).
#
# Forward-mode automatic differentiation in the browser: ship a frozen wasm
# module that computes EXACT gradients/Jacobians of a Julia function, no host,
# no finite differences. ForwardDiff is the workhorse autodiff backend across
# SciML (DifferentialEquations Jacobians, Optim/NLsolve, parameter fitting).
#
# What compiles as-is vs. what needs an overlay
# ---------------------------------------------
# `ForwardDiff.derivative(f, ::Real)` compiles STRAIGHT from the real impl: it
# seeds a single-partial `Dual{T}(x, 1)` and reads back one partial — plain dual
# arithmetic WasmGC handles. No overlay needed.
#
# `gradient`/`jacobian`/`hessian` do NOT compile natively: for a length-N input
# they build a `Partials{N}` seed matrix through ForwardDiff's chunk/`Config`/
# `@generated` seeding machinery, which embeds a cyclic `Method` constant WT
# can't emit ("cannot compile `Method` … object graph references itself").
#
# The elegant fix — reuse the path that already works. Forward-mode partials
# never cross slots (each output partial k depends only on input slot k, via the
# chain rule), so computing ONE partial at a time (`Partials{1}`, the working
# `derivative` seed) N times is BIT-IDENTICAL to ForwardDiff's `Partials{N}`
# vector mode — just more passes. We seed the i-th unit direction, evaluate, and
# read back partial 1, looping over components with definite for-loops (no
# chunk machinery, no `Val(N)` lift, no `@generated`). Verified differentially
# against native ForwardDiff in test/fuzz/forwarddiff_diff.jl.
module WasmTargetForwardDiffExt

using WasmTarget
using ForwardDiff
using ForwardDiff: Dual, Tag, partials
using Base.Experimental: @overlay

const WMT = WasmTarget.WASM_METHOD_TABLE

# Seed a Dual vector for the i-th unit direction (component i gets partial 1.0,
# the rest 0.0) — exactly the `derivative` seed, one direction at a time.
@inline function _wt_seed(::Type{T}, x::Vector{Float64}, i::Int) where {T}
    n = length(x)
    xd = Vector{Dual{T,Float64,1}}(undef, n)
    for j in 1:n
        xd[j] = Dual{T}(x[j], ifelse(i == j, 1.0, 0.0))
    end
    return xd
end

# ∇f : Rⁿ → Rⁿ.  N single-partial passes; gᵢ = ∂f/∂xᵢ.
@overlay WMT function ForwardDiff.gradient(f::F, x::Vector{Float64}) where {F}
    T = typeof(Tag(f, Float64))
    n = length(x)
    g = Vector{Float64}(undef, n)
    for i in 1:n
        y = f(_wt_seed(T, x, i))           # y :: Dual{T,Float64,1}
        g[i] = partials(y, 1)
    end
    return g
end

# J f : Rⁿ → Rᵐˣⁿ.  Column i is the directional derivative along eᵢ; the first
# pass also fixes the output length m (= length of f's vector result).
@overlay WMT function ForwardDiff.jacobian(f::F, x::Vector{Float64}) where {F}
    T = typeof(Tag(f, Float64))
    n = length(x)
    y1 = f(_wt_seed(T, x, 1))              # Vector{Dual{T,Float64,1}}
    m = length(y1)
    J = Matrix{Float64}(undef, m, n)
    for k in 1:m
        J[k, 1] = partials(y1[k], 1)
    end
    for i in 2:n
        yi = f(_wt_seed(T, x, i))
        for k in 1:m
            J[k, i] = partials(yi[k], 1)
        end
    end
    return J
end

# Hessian = forward-over-forward (∂²f/∂xᵢ∂xⱼ). Native `hessian` compiles under WT
# but SILENTLY MISCOMPILES (its nested-Dual seeding via the chunk machinery yields
# wrong values), so we overlay it with explicit nested single-partial seeding —
# the same Partials{1} path that gradient/jacobian verify, one level deep. Two
# DISTINCT tags (inner T1 over Float64, outer T2 over Dual{T1}) avoid perturbation
# confusion. Each entry seeds the j-direction in the inner value and the
# i-direction in the outer partial; the result's outer-partial's inner-partial is
# ∂²f/∂xᵢ∂xⱼ. O(n²) evaluations — bit-identical to native ForwardDiff.hessian.
@overlay WMT function ForwardDiff.hessian(f::F, x::Vector{Float64}) where {F}
    n = length(x)
    T1 = typeof(Tag(f, Float64))
    T2 = typeof(Tag(f, Dual{T1,Float64,1}))
    H = Matrix{Float64}(undef, n, n)
    for i in 1:n
        for j in 1:n
            xd = Vector{Dual{T2,Dual{T1,Float64,1},1}}(undef, n)
            for k in 1:n
                vk = Dual{T1}(x[k], ifelse(k == j, 1.0, 0.0))   # inner value seeds e_j
                pk = Dual{T1}(ifelse(k == i, 1.0, 0.0), 0.0)    # outer partial seeds e_i
                xd[k] = Dual{T2}(vk, pk)
            end
            res = f(xd)                                          # Dual{T2,Dual{T1,Float64,1},1}
            H[i, j] = partials(partials(res, 1), 1)
        end
    end
    return H
end

# In-place variants. Native `gradient!`/`jacobian!`/`hessian!` route through the
# preallocated `Config` + chunk machinery (the cyclic-`Method` wall), so overlay
# them to the alloc forms above (which DO compile) and copy into the caller's
# buffer. Same values, just a `copyto!`.
# derivative! — derivative of a VECTOR-valued f: R → Rᵐ into a preallocated
# buffer. One single-partial seed (the working `derivative` path); partial k of
# the result is df_k/dx. (Scalar derivative needs no `!`; it already compiles.)
@overlay WMT function ForwardDiff.derivative!(out::Vector{Float64}, f::F, x::Float64) where {F}
    T = typeof(Tag(f, Float64))
    yd = f(Dual{T}(x, 1.0))                # Vector{Dual{T,Float64,1}}
    for k in 1:length(out)
        out[k] = partials(yd[k], 1)
    end
    return out
end

@overlay WMT function ForwardDiff.gradient!(out::Vector{Float64}, f::F, x::Vector{Float64}) where {F}
    copyto!(out, ForwardDiff.gradient(f, x))
    return out
end

@overlay WMT function ForwardDiff.jacobian!(out::Matrix{Float64}, f::F, x::Vector{Float64}) where {F}
    copyto!(out, ForwardDiff.jacobian(f, x))
    return out
end

@overlay WMT function ForwardDiff.hessian!(out::Matrix{Float64}, f::F, x::Vector{Float64}) where {F}
    copyto!(out, ForwardDiff.hessian(f, x))
    return out
end

end # module
