# WasmTargetLinearAlgebraExt — LinearAlgebra stdlib integration (overlays).
#
# The VECTOR value-level surface that lowers from LinearAlgebra's GENERIC
# (pure-Julia) methods — norm/normalize/cross and INTEGER dot — needs no
# overlay (it compiles from the real impls; see test/fuzz/catalogue.jl
# mod=:linalg). This extension carries the reroutes for the BLAS/LAPACK-backed
# methods WT cannot lower.
#
# FLOAT `dot`: dot(::Vector{<:BlasFloat}) dispatches to BLAS (matmul.jl), a
# `ccall` WT cannot lower — it otherwise compiles to a SILENT 0.0. Reroute to
# Base's OWN generic dot(::AbstractArray, ::AbstractArray) via `invoke`. This is
# a true REROUTE (the generic method IS the reference algorithm: sequential
# `s += conj(x[i])*y[i]`), not a reimplementation. It is value-identical to BLAS
# modulo floating-point summation-ORDER rounding, which the differential oracle
# tolerates (oracle_policy.jl: rtol 1e-9). Verified: the reroute matches native
# BLAS dot 200/200 on both well-conditioned and wild (1e±6 mixed-magnitude)
# inputs, and 0/5000 random pairs exceed rtol 1e-9 at catalogue vector lengths.
# (Ill-conditioned long vectors with heavy cancellation can exceed rtol — a
# per-op conditioning matter, not a method error; downstream geometry is
# well-conditioned.)
module WasmTargetLinearAlgebraExt

using WasmTarget
using LinearAlgebra
using Base.Experimental: @overlay

@overlay WasmTarget.WASM_METHOD_TABLE LinearAlgebra.dot(x::Vector{T}, y::Vector{T}) where {T<:Union{Float32,Float64}} =
    invoke(LinearAlgebra.dot, Tuple{AbstractArray,AbstractArray}, x, y)

# MATMUL: *(::Matrix{<:BlasFloat}, ::Matrix/::Vector) dispatches to BLAS
# gemm/gemv (matmul.jl), a ccall WT cannot lower (it silent-zeros). Reroute to
# the textbook triple/double product — exactly what LinearAlgebra's own
# generic_matmatmul!/generic_matvecmul! compute for non-BLAS types — which is
# value-identical to BLAS modulo summation-ORDER rounding (oracle rtol 1e-9).
# `invoke`-to-generic does NOT work here (the generic `*` re-dispatches through
# mul! straight back to BLAS), so the kernel is written out. Verified vs native
# 40/40 (matmul) and 40/40 (matvec).
@overlay WasmTarget.WASM_METHOD_TABLE function Base.:*(A::Matrix{T}, B::Matrix{T}) where {T<:Union{Float32,Float64}}
    mA, nA = size(A)
    nA == size(B, 1) || throw(DimensionMismatch("matmul"))
    nB = size(B, 2)
    C = zeros(T, mA, nB)
    @inbounds for j in 1:nB, k in 1:nA, i in 1:mA
        C[i, j] += A[i, k] * B[k, j]
    end
    return C
end

@overlay WasmTarget.WASM_METHOD_TABLE function Base.:*(A::Matrix{T}, x::Vector{T}) where {T<:Union{Float32,Float64}}
    mA, nA = size(A)
    nA == length(x) || throw(DimensionMismatch("matvec"))
    y = zeros(T, mA)
    @inbounds for j in 1:nA, i in 1:mA
        y[i] += A[i, j] * x[j]
    end
    return y
end

# det / logdet: native dispatches to LAPACK LU (getrf), a ccall WT cannot lower
# (it silent-fails / emits invalid wasm). Reroute through Base's OWN pure-Julia
# `generic_lufact!` — the SAME partial-pivot LU native uses, just non-BLAS — and
# read det/logdet off it. Value-identical to LAPACK modulo pivoting/rounding
# (oracle rtol 1e-9). Verified vs native 40/40 each. (inv/`\`/cholesky/eigen/svd
# need more than an LU reroute — see FINDINGS "Matrix surface".)
@overlay WasmTarget.WASM_METHOD_TABLE LinearAlgebra.det(A::Matrix{T}) where {T<:Union{Float32,Float64}} =
    LinearAlgebra.det(LinearAlgebra.generic_lufact!(copy(A)))

@overlay WasmTarget.WASM_METHOD_TABLE LinearAlgebra.logdet(A::Matrix{T}) where {T<:Union{Float32,Float64}} =
    LinearAlgebra.logdet(LinearAlgebra.generic_lufact!(copy(A)))

# ── DECOMPOSITIONS: hand-rolled, WT-compilable textbook algorithms ──────────
# The library's LAPACK/QR/Householder machinery emits invalid wasm, and
# GenericLinearAlgebra's pure-Julia algorithms hit the SAME WT codegen wall (both
# verified — see FINDINGS "Matrix surface"). But simple textbook algorithms
# COMPILE and match native under the tolerance oracle (rtol 1e-9), verified 30/30
# each. Float64 ONLY: Float32 iterative algorithms differ from native by ~1e-7
# (Float32 eps) > the oracle rtol, so they are not oracle-verifiable (deferred).

# LU solve / inv: Base's `generic_lufact!` compiles (it powers det/logdet);
# combine with manual forward/back substitution on its packed factors + pivots.
function _wt_lu_solve(A::Matrix{Float64}, b::Vector{Float64})
    F = LinearAlgebra.generic_lufact!(copy(A)); LU = F.factors; n = size(LU, 1)
    y = b[F.p]
    @inbounds for i in 1:n; s = y[i]; for j in 1:i-1; s -= LU[i, j] * y[j]; end; y[i] = s; end
    x = similar(y)
    @inbounds for i in n:-1:1; s = y[i]; for j in i+1:n; s -= LU[i, j] * x[j]; end; x[i] = s / LU[i, i]; end
    x
end
function _wt_lu_inv(A::Matrix{Float64})
    n = size(A, 1); F = LinearAlgebra.generic_lufact!(copy(A)); LU = F.factors; p = F.p
    X = zeros(Float64, n, n)
    @inbounds for col in 1:n
        y = zeros(Float64, n)
        for i in 1:n; y[i] = (p[i] == col) ? 1.0 : 0.0; end
        for i in 1:n; s = y[i]; for j in 1:i-1; s -= LU[i, j] * y[j]; end; y[i] = s; end
        for i in n:-1:1; s = y[i]; for j in i+1:n; s -= LU[i, j] * X[j, col]; end; X[i, col] = s / LU[i, i]; end
    end
    X
end
# svdvals via ONE-SIDED Jacobi (rotates columns of A directly — accurate, unlike
# the AᵀA method which squares the condition number). Ensure m≥n by transposing
# (svdvals(Aᵀ) == svdvals(A)). Returns the min(m,n) singular values, desc.
function _wt_osj_svdvals(A0::Matrix{Float64})
    A = size(A0, 1) >= size(A0, 2) ? copy(A0) : permutedims(A0)
    m = size(A, 1); n = size(A, 2)
    @inbounds for _ in 1:60
        conv = true
        for p in 1:n-1, q in p+1:n
            app = 0.0; aqq = 0.0; apq = 0.0
            for i in 1:m; aip = A[i, p]; aiq = A[i, q]; app += aip*aip; aqq += aiq*aiq; apq += aip*aiq; end
            (apq == 0.0 || abs(apq) < 1.0e-15 * sqrt(app * aqq)) && continue
            conv = false
            τ = (aqq - app) / (2apq); t = sign(τ) / (abs(τ) + sqrt(1 + τ*τ))
            c = 1.0 / sqrt(1 + t*t); s = c * t
            for i in 1:m; aip = A[i, p]; aiq = A[i, q]; A[i, p] = c*aip - s*aiq; A[i, q] = s*aip + c*aiq; end
        end
        conv && break
    end
    sv = Vector{Float64}(undef, n)
    @inbounds for j in 1:n; nj = 0.0; for i in 1:m; nj += A[i, j] * A[i, j]; end; sv[j] = sqrt(nj); end
    sort!(sv, rev=true); sv
end

@overlay WasmTarget.WASM_METHOD_TABLE Base.inv(A::Matrix{Float64}) = _wt_lu_inv(A)
@overlay WasmTarget.WASM_METHOD_TABLE Base.:\(A::Matrix{Float64}, b::Vector{Float64}) = _wt_lu_solve(A, b)
@overlay WasmTarget.WASM_METHOD_TABLE LinearAlgebra.svdvals(A::Matrix{Float64}) = _wt_osj_svdvals(A)
# NOTE: eigvals/eigen (symmetric) — the Jacobi kernel COMPILES + matches native
# (verified), but `eigvals(A::Symmetric; sortby)` routes through kwarg-dispatch
# that a positional @overlay does not intercept (it still reaches LAPACK →
# WasmValidationError). The right interception target (eigvals!/the kwcall body)
# is a separate follow-up. See FINDINGS "Matrix surface".

end # module
