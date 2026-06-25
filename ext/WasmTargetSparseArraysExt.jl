# WasmTargetSparseArraysExt — SparseArrays stdlib integration.
#
# SparseArrays is the foundation for SciML-scale work (sparse Jacobians, sparse
# linear systems). The blocker is at the very bottom: constructing a
# `SparseMatrixCSC` at all. Two overlays unlock the foundation; once a CSC
# exists, the READ/REDUCE/MATVEC paths compile straight from the real
# SparseArrays implementations (they only do static field access + loops).
#
# (1) `sparse_check_Ti(m, n, Ti)` builds a `Ti`-parameterized inner closure
#     (`throwTi`) whose type is formed via `Core.apply_type` on a runtime Type —
#     a type-level construct WasmGC can't lower (same class as the `cor`
#     type-instability in Statistics). WT only ever compiles `Ti == Int64`, where
#     the bounds always hold, so we validate inline with a plain throw and no
#     closure. Semantically identical for Int64.
#
# (2) `sparse(A::Matrix{Float64})` — the generic dense→CSC path additionally
#     trips an unresolved dynamic `getfield(::SparseMatrixCSC, ::Symbol)`. Replace
#     it with a textbook column-scan CSC build via the (now-compilable) low-level
#     constructor. Bit-identical to native `sparse(A)` (same column-major,
#     structural-zeros-dropped CSC).
#
# NB: ops that BUILD A NEW sparse result (sparse*sparse, sparse±sparse,
# transpose(sparse), scalar*sparse, sparse\b) currently trip a WT codegen crash
# in the generic result-CSC construction (`BoundsError: Vector{Type}[3]`) and
# are NOT yet overlaid — that's the next increment (hand-roll each, like the
# LinearAlgebra factorizations). The SuiteSparse `\`/factorizations are the
# genuine wall (C library; needs a pure-Julia sparse LU). See test/fuzz/FINDINGS.md.
module WasmTargetSparseArraysExt

using WasmTarget
using SparseArrays
using Base.Experimental: @overlay

# (1) Drop the Ti-parameterized `throwTi` closure; validate inline for Int64.
@overlay WasmTarget.WASM_METHOD_TABLE function SparseArrays.sparse_check_Ti(m::Integer, n::Integer, Ti::Type)
    (0 ≤ m) || throw(ArgumentError("number of rows must be ≥ 0"))
    (0 ≤ n) || throw(ArgumentError("number of columns must be ≥ 0"))
    nothing
end

# (2) Dense → CSC via a hand-rolled column scan (column-major, drop structural
# zeros) + the low-level constructor. Bit-identical to native `sparse(A)`.
@overlay WasmTarget.WASM_METHOD_TABLE function SparseArrays.sparse(A::Matrix{Float64})
    m, n = size(A)
    colptr = Vector{Int64}(undef, n + 1)
    colptr[1] = 1
    rowval = Int64[]
    nzval = Float64[]
    @inbounds for j in 1:n
        for i in 1:m
            v = A[i, j]
            if v != 0.0
                push!(rowval, i)
                push!(nzval, v)
            end
        end
        colptr[j + 1] = length(rowval) + 1
    end
    SparseMatrixCSC{Float64,Int64}(m, n, colptr, rowval, nzval)
end

end # module
