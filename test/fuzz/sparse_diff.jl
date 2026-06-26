# ============================================================================
# Differential fuzz of the SparseArrays stdlib — FOUNDATION (step 1).
# ============================================================================
# SparseArrays construction (`sparse(::Matrix)`) is unlocked by two overlays in
# ext/WasmTargetSparseArraysExt.jl (sparse_check_Ti + a hand-rolled dense→CSC).
# Once a CSC exists, the READ/REDUCE/MATVEC paths compile from the real
# SparseArrays implementations. This file differentially verifies that
# foundation (wasm vs native, same oracle as core): construction round-trips,
# nnz, reductions, sparse·vector, sparse·dense.
#
# Tested dense-in / dense-out (sparse used INTERNALLY) so the matrix bridge can
# marshal inputs/outputs — mirrors how linalg_diff verifies factorization objects.
# Loaded by fuzz_suite.jl AFTER fuzz/run.jl. Entry: run_sparse_tests().
# Exports SPARSE_VERIFIED for stdlib_coverage.jl.

using SparseArrays
using LinearAlgebra
using Random
using Test

const _SP_B = WasmTarget.Bridge

function _sp_diff(fn, argTs::Tuple, inputs::Vector, rettype)
    res = bridge_run_args(fn, argTs, inputs; rettype = rettype)
    res isa Vector || return false
    rdesc = _SP_B.descriptor(rettype)[1]
    for (i, r) in enumerate(res)
        a = inputs[i]
        nat = try (true, fn(deepcopy.(a)...)) catch; (false, nothing) end
        ok = r[1] === :ok ? (nat[1] && _SP_B.tree_matches(rdesc, nat[2], r[2])) : !nat[1]
        ok || return false
    end
    return true
end

# deterministic sparse-ish dense generators (≈half the entries zeroed)
_sp_rmat(rng, m, n) = (A = Float64[2rand(rng) - 1 for _ in 1:m, _ in 1:n];
                       for i in eachindex(A); rand(rng) < 0.5 && (A[i] = 0.0); end; A)
_sp_rvec(rng, n)    = Float64[2rand(rng) - 1 for _ in 1:n]

# SparseArrays names this file verifies (for stdlib_coverage.jl). `sparse`/`nnz`
# directly; the value ops below ground that sparse arithmetic is correct.
const SPARSE_VERIFIED = Set{Symbol}([:sparse, :nnz, :issparse, :nonzeros, :rowvals,
    :spzeros, :dropzeros, :findnz, :droptol!, :sparsevec, :nzrange,
    :spdiagm, :blockdiag])

# dense-in / dense-out wrappers, sparse used internally
_sp_round(A)   = Matrix(sparse(A))            # construct + densify (round-trip)
_sp_nnz(A)     = nnz(sparse(A))               # structural nonzero count
_sp_isspar(A)  = issparse(sparse(A))          # predicate (always true)
_sp_nzsum(A)   = sum(nonzeros(sparse(A)))     # nonzeros() + reduce
_sp_rowsum(A)  = sum(rowvals(sparse(A)))      # rowvals() + reduce (Int)
_sp_sum(A)     = sum(sparse(A))               # full reduction
_sp_max(A)     = maximum(abs, sparse(A))      # mapped reduction
_sp_mv(A, x)   = sparse(A) * x                # sparse · vector
_sp_spdense(A) = Matrix(sparse(A) * Matrix(sparse(A)))  # sparse · dense
# result-building ops (unlocked by the is_struct_type carve-out + the outer-ctor
# overlay) — each builds a NEW sparse result, compared densified
_sp_matmul(A, B) = Matrix(sparse(A) * sparse(B))   # sparse · sparse → sparse
_sp_scale(A)     = Matrix(2.5 * sparse(A))         # scalar · sparse
_sp_copy(A)      = Matrix(copy(sparse(A)))         # copy
_sp_drop(A)      = Matrix(dropzeros(sparse(A)))    # dropzeros
_sp_spz(n)       = Matrix(spzeros(n, n))           # spzeros
_sp_transpose(A) = Matrix(permutedims(sparse(A)))  # CSC transpose (ext overlay)
_sp_findnz(A)    = sum(findnz(sparse(A))[3])       # findnz (3rd = values)
_sp_droptol(A)   = Matrix(droptol!(sparse(A), 0.4))# droptol!
_sp_spvec(v)     = Vector(sparsevec(v))            # sparsevec round-trip
_sp_nzrange(A)   = (S = sparse(A); s = 0; for j in 1:S.n; s += length(nzrange(S, j)); end; s)  # nzrange
_sp_spdiagm(v)   = Matrix(spdiagm(0 => v))            # spdiagm (ext overlay)
_sp_hcat(A, Bm)  = Matrix(hcat(sparse(A), sparse(Bm)))     # hcat (ext overlay)
_sp_vcat(A, Bm)  = Matrix(vcat(sparse(A), sparse(Bm)))     # vcat (ext overlay)
_sp_blockd(A, Bm)= Matrix(blockdiag(sparse(A), sparse(Bm)))# blockdiag (ext overlay)

function run_sparse_tests(; reps::Int = 40)
    FuzzHarness.NODE_OK || (@test_skip true; return)
    rng = MersenneTwister(0x5A11)
    sq()  = [ (n = rand(rng, 2:5); (_sp_rmat(rng, n, n),)) for _ in 1:reps ]
    sqv() = [ (n = rand(rng, 2:5); (_sp_rmat(rng, n, n), _sp_rvec(rng, n))) for _ in 1:reps ]
    @testset "construction + queries" begin
        @test _sp_diff(_sp_round,  (Matrix{Float64},), sq(), Matrix{Float64})  # sparse + Matrix
        @test _sp_diff(_sp_nnz,    (Matrix{Float64},), sq(), Int64)            # nnz
        @test _sp_diff(_sp_isspar, (Matrix{Float64},), sq(), Bool)            # issparse
        @test _sp_diff(_sp_nzsum,  (Matrix{Float64},), sq(), Float64)         # nonzeros
        @test _sp_diff(_sp_rowsum, (Matrix{Float64},), sq(), Int64)           # rowvals
    end
    @testset "reductions + products" begin
        @test _sp_diff(_sp_sum,     (Matrix{Float64},), sq(), Float64)        # sum
        @test _sp_diff(_sp_max,     (Matrix{Float64},), sq(), Float64)        # maximum(abs,·)
        @test _sp_diff(_sp_mv,      (Matrix{Float64}, Vector{Float64}), sqv(), Vector{Float64})  # S·x
        @test _sp_diff(_sp_spdense, (Matrix{Float64},), sq(), Matrix{Float64})  # S·dense
    end
    @testset "result-building ops (carve-out + outer-ctor overlay)" begin
        ssq() = [ (n = rand(rng, 2:4); (_sp_rmat(rng, n, n), _sp_rmat(rng, n, n))) for _ in 1:reps ]
        @test _sp_diff(_sp_matmul, (Matrix{Float64}, Matrix{Float64}), ssq(), Matrix{Float64})  # S·S
        @test _sp_diff(_sp_scale,  (Matrix{Float64},), sq(), Matrix{Float64})                   # a·S
        @test _sp_diff(_sp_copy,   (Matrix{Float64},), sq(), Matrix{Float64})                   # copy
        @test _sp_diff(_sp_drop,   (Matrix{Float64},), sq(), Matrix{Float64})                   # dropzeros
        @test _sp_diff(_sp_spz,    (Int64,), [ (rand(rng, 2:6),) for _ in 1:reps ], Matrix{Float64})  # spzeros
    end
    @testset "transpose / queries / mutators" begin
        @test _sp_diff(_sp_transpose, (Matrix{Float64},), sq(), Matrix{Float64})  # permutedims (ext overlay)
        @test _sp_diff(_sp_findnz,    (Matrix{Float64},), sq(), Float64)          # findnz
        @test _sp_diff(_sp_droptol,   (Matrix{Float64},), sq(), Matrix{Float64})  # droptol!
        @test _sp_diff(_sp_nzrange,   (Matrix{Float64},), sq(), Int64)            # nzrange
        @test _sp_diff(_sp_spvec, (Vector{Float64},),
                       [ (_sp_rvec(rng, rand(rng, 3:7)),) for _ in 1:reps ], Vector{Float64})  # sparsevec
    end
    @testset "construction / concatenation (ext overlays)" begin
        pair() = [ (n = rand(rng, 2:4); (_sp_rmat(rng, n, n), _sp_rmat(rng, n, n))) for _ in 1:reps ]
        @test _sp_diff(_sp_spdiagm, (Vector{Float64},),
                       [ (_sp_rvec(rng, rand(rng, 2:5)),) for _ in 1:reps ], Matrix{Float64})  # spdiagm
        @test _sp_diff(_sp_hcat,    (Matrix{Float64}, Matrix{Float64}), pair(), Matrix{Float64})  # hcat
        @test _sp_diff(_sp_vcat,    (Matrix{Float64}, Matrix{Float64}), pair(), Matrix{Float64})  # vcat
        @test _sp_diff(_sp_blockd,  (Matrix{Float64}, Matrix{Float64}), pair(), Matrix{Float64})  # blockdiag
    end
end
