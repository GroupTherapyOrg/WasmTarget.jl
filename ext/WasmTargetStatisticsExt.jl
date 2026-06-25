# WasmTargetStatisticsExt — Statistics stdlib integration.
#
# Statistics compiles almost entirely from its REAL implementations (mean,
# var, std, cov, middle, median!, quantile! need no stdlib-specific code —
# the pilot's fixes all landed in the core compiler). This extension carries
# the `cor` 2-arg reroute below plus the 1.13-gated wrapper reroutes.
module WasmTargetStatisticsExt

using WasmTarget
using Statistics
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
# approximation. (1-arg `cor(x)` is left as-is: it has no ledger gap and its
# value-independent `one(float(eltype))` result genuinely needs the type-level
# path; failing to compile there is loud, not a wrong value.)
@overlay WasmTarget.WASM_METHOD_TABLE Statistics.cor(x::AbstractVector, y::AbstractVector) =
    Statistics.corm(x, Statistics.mean(x), y, Statistics.mean(y))

# On 1.13, the `median(v)` / `quantile(v, p)` WRAPPER specializations inline
# into an IR shape that hits a known generator limitation (a dead-coded
# boundscheck arm interacting with an intra-range jump target — see the
# stdlib-statistics branch notes). Their LITERAL definitions compile
# correctly, so reroute through them; semantically identical by definition.
@static if VERSION >= v"1.13-"
    @overlay WasmTarget.WASM_METHOD_TABLE Statistics.median(v::AbstractVector) =
        Statistics.median!(copy(v))
    @overlay WasmTarget.WASM_METHOD_TABLE Statistics.quantile(v::AbstractVector, p::Real) =
        Statistics.quantile!(copy(v), p)
end

# mean!(r, A) reduces A into r via sum!+rescale; the dim-reduction machinery
# emits invalid wasm. For the dest-vector / matrix form it is row-means
# (r[i] = mean(A[i, :])) — written out explicitly. Bit-identical to native.
@overlay WasmTarget.WASM_METHOD_TABLE function Statistics.mean!(r::Vector{Float64}, A::Matrix{Float64})
    m = size(A, 1); n = size(A, 2)
    @inbounds for i in 1:m
        s = 0.0
        for j in 1:n; s += A[i, j]; end
        r[i] = s / n
    end
    r
end

end # module
