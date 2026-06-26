# WasmTargetStaticArraysExt — StaticArrays (SVector) support.
#
# SVector{N,T} === SArray{Tuple{N},T,1,N} is NOT a heap array: it is a struct
# wrapping a single field `data::NTuple{L,T}`. Two things make WT mis-handle it:
#
# (1) STRUCT-vs-ARRAY: SVector <: StaticArray <: AbstractArray, so WT's
#     `is_struct_type` would give it the generic array layout and its `.data`
#     NTuple would be unreachable (getindex/iterate trap at runtime). Register
#     `:SArray` in `_ARRAY_STRUCT_CARVEOUT` so WT lays it out as the concrete
#     NTuple-backed struct it is (the SparseMatrixCSC / ForwardDiff-Dual lever).
#
# (2) CONSTRUCTION: every SVector ctor — `SVector{N,T}(x...)` and
#     `SVector{N,T}(::Tuple)` alike — routes through `StaticArrays.construct_type`,
#     a pile of pure type-level machinery (`adapt_size`/`adapt_eltype`/
#     `typeintersect`/`has_size`/…). Native folds it to the concrete
#     `Type{SVector{N,T}}`; WT's interpreter (concrete-eval disabled to protect
#     overlays) gives up and infers `Any`, so the whole SVector — and every
#     `getindex` off it — boxes and traps. For an ALREADY-fully-parameterized
#     `SArray{S,T,N,L}`, `construct_type` is the identity (it only adapts missing
#     size/eltype). Overlay it to return that type directly: a one-method fix at
#     the root that re-concretises the result and lets the normal (type-stable)
#     inner ctor run, for both the positional and tuple construction forms.
#
# Verified bit/tolerance-identical to native — see test/fuzz/staticarrays_diff.jl.
# This is what unblocks SimpleDiffEq's SimpleTsit5 (its Butcher tableau lives in
# SVector{6/21/22} coefficient caches). Scope: fully-parameterized `SVector{N,T}`
# (all N ≥ 1, including the degenerate single-element vector) — construction
# (positional / tuple / converting-eltype), getindex, iterate/destructure,
# arithmetic and broadcast. SMatrix / MArray are future scope.
module WasmTargetStaticArraysExt

using WasmTarget
using StaticArrays
using Base.Experimental: @overlay

const WMT = WasmTarget.WASM_METHOD_TABLE

function __init__()
    # SVector/SMatrix are <:AbstractArray but real NTuple-backed structs.
    push!(WasmTarget._ARRAY_STRUCT_CARVEOUT, :SArray)
end

# For an already-concrete SArray, construct_type is the identity — return it so WT
# infers the result type (instead of Any) and the normal inner ctor takes over.
@overlay WMT StaticArrays.construct_type(::Type{SArray{S, T, N, L}}, x) where {S <: Tuple, T, N, L} =
    SArray{S, T, N, L}

end # module
