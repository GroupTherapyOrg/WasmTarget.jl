# WasmTargetStatisticsExt — Statistics stdlib integration.
#
# Statistics compiles almost entirely from its REAL implementations (mean,
# var, std, cov, middle, median!, quantile! need no stdlib-specific code —
# the pilot's fixes all landed in the core compiler). This extension carries
# the `cor` 2-arg reroute below plus the 1.13-gated wrapper reroutes.
module WasmTargetStatisticsExt

using WasmTarget
using Statistics: Statistics
using Base.Experimental: @overlay

# 2-arg `cor(x, y)` carries an `x === y → 1.0` fast path whose result is
# `one(float(nonmissingtype(eltype(x))))` — a pure TYPE-LEVEL computation. WT
# disables concrete-eval (to respect overlays), so the native optimizer's fold of
# that chain to a constant does NOT happen; it survives as runtime `dynamic`
# dispatch on Type VALUES that WT can't lower → `unreachable` stub → the relooper
# leaves a successor block's consumer with an empty operand stack →
# `WasmValidationError: expected a type but nothing on stack` (gaps 3fd2f07bfc5c,
# 5d7d44dd7cb2, 96ce40f373de, eadbce55d36d). Reroute through `corm`, which is the
# actual computation and value-level throughout. `corm(x, mean(x), y, mean(y))` is
# BIT-EXACT equal to native `cor(x, y)` for every input — including `x === y`,
# where `clampcor` yields exactly 1.0 — so this is semantically identical, not an
# approximation. (corm accumulates under `@simd`: native vectorizes the sum in an order its
# target decides, so the fuzz lane compares cor within its @simd allowance.) (1-arg `cor(x)` is left as-is: it has no ledger gap and its
# value-independent `one(float(eltype))` result genuinely needs the type-level
# path; failing to compile there is loud, not a wrong value.)
# parity(quarantine: Julia's cor(x, y) keeps an x === y branch whose one(float(eltype)) is a run-time dispatch on type values WT does not lower; corm is the same computation.)
@overlay WasmTarget.WASM_METHOD_TABLE Statistics.cor(x::AbstractVector, y::AbstractVector) =
    Statistics.corm(x, Statistics.mean(x), y, Statistics.mean(y))

# The stdlib implementation has already established equal lengths before its
# `eachindex(x, y)` loop, but that multi-array iterator retains a lazy
# AnnotatedString mismatch path. This dense specialization is the same corm
# accumulation over the one validated index domain.
# parity(quarantine: Julia's corm iterates eachindex(x, y), whose mismatch path reaches a lazy AnnotatedString WT does not compile; the lengths are checked first, so one index domain is the same loop.)
@overlay WasmTarget.WASM_METHOD_TABLE function Statistics.corm(
        x::Vector{T}, mx::T, y::Vector{T}, my::T) where {T<:Union{Float32,Float64}}
    n = length(x)
    length(y) == n || throw(DimensionMismatch("inconsistent lengths"))
    n > 0 || throw(ArgumentError("correlation only defined for non-empty vectors"))
    @inbounds begin
        xx = zero(sqrt(abs2(one(x[1]))))
        yy = zero(sqrt(abs2(one(y[1]))))
        xy = zero(x[1] * y[1]')
        @simd for i in eachindex(x)
            xi = x[i] - mx
            yi = y[i] - my
            xx += abs2(xi)
            yy += abs2(yi)
            xy += xi * yi'
        end
    end
    Statistics.clampcor(xy / max(xx, yy) / sqrt(min(xx, yy) / max(xx, yy)))
end

# Statistics only requires the requested quantile interval to be ordered and
# explicitly permits mutation of `v`. Fully sorting through WT's pure-Julia sort
# implementation is semantically exact and avoids Julia's host-header radix path.
# parity(quarantine: Julia's _quantilesort! sorts through the radix path, which reads host object headers; a full sort is the ordering Statistics requires.)
@overlay WasmTarget.WASM_METHOD_TABLE function Statistics._quantilesort!(
        v::AbstractVector, sorted::Bool, minp::Real, maxp::Real)
    isempty(v) && throw(ArgumentError("empty data vector"))
    if !sorted
        sort!(v)
    end
    if (ismissing(v[end]) || (v[end] isa Number && isnan(v[end]))) ||
       any(x -> ismissing(x) || (x isa Number && isnan(x)), v)
        throw(ArgumentError("quantiles are undefined in presence of NaNs or missing values"))
    end
    return v
end

# On 1.13, the `median(v)` / `quantile(v, p)` WRAPPER specializations inline
# into an IR shape that hits a known generator limitation (a dead-coded
# boundscheck arm interacting with an intra-range jump target — see the
# stdlib-statistics branch notes). Their LITERAL definitions compile
# correctly, so reroute through them; semantically identical by definition.
@static if VERSION >= v"1.13-"
    # parity(quarantine: on 1.13 median(v)'s wrapper inlines into a control region the stackifier does not nest, dev/MARCH.md 13.10; median!(copy(v)) is its definition.)
    @overlay WasmTarget.WASM_METHOD_TABLE Statistics.median(v::AbstractVector) =
        Statistics.median!(copy(v))
    # parity(quarantine: on 1.13 quantile(v, p)'s wrapper inlines into a control region the stackifier does not nest, dev/MARCH.md 13.10; quantile!(copy(v), p) is its definition.)
    @overlay WasmTarget.WASM_METHOD_TABLE Statistics.quantile(v::AbstractVector, p::Real) =
        Statistics.quantile!(copy(v), p)
end

# Statistics.mean!(R, A) is `sum!(R, A; init=true)`, then `R .= R .* (max(1, length(R)) //
# length(A))`. WT does not compile sum!'s dim-reduction machinery (it emitted invalid wasm);
# for the row form (R a Vector, A a Matrix) that sum is each row's sequential sum from 0.0,
# written out here, followed by Julia's own rescale. The rescale is Julia's, not `/ n`: the
# division answered differently in 754 of 2000 random inputs.
# parity(quarantine: Julia's sum! over a matrix dimension — Base's mapreducedim! machinery,
# which WT does not compile; the row sums follow its column-major order.)
@overlay WasmTarget.WASM_METHOD_TABLE function Statistics.mean!(r::Vector{Float64}, A::Matrix{Float64})
    m = size(A, 1); n = size(A, 2)
    @inbounds for i in 1:m
        s = 0.0
        for j in 1:n; s += A[i, j]; end
        r[i] = s
    end
    x = max(1, length(r)) // length(A)
    r .= r .* x
    return r
end

end # module
