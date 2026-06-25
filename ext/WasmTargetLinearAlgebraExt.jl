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

end # module
