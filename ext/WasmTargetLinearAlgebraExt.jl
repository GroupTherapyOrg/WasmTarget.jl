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

end # module
