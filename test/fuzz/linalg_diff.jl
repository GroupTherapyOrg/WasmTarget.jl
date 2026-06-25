# ============================================================================
# Differential verification of the LinearAlgebra MATRIX surface.
# ============================================================================
# The catalogue generator (catalogue.jl) produces Vector/Dict/Set values but NOT
# Matrix, and the matrix LA ops need WELL-FORMED structured inputs
# (square / symmetric / conformable). So the matrix surface is verified HERE by
# direct `bridge_run_args` differential sweeps — the SAME oracle the fuzzer uses
# (`WasmTarget.Bridge.tree_matches` → `_float_match`, rtol 1e-9), over
# deterministic seeded inputs. This file GROWS per LinearAlgebra-campaign
# increment (pure ops → factorizations → structured types).
#
# Each op is wrapped in a NAMED function so the operation is a CALLEE (where the
# WASM_METHOD_TABLE overlays for the BLAS-backed ops — *, dot — apply, exactly
# as in real downstream cell functions), not the compiled entry point.
#
# Loaded by fuzz_suite.jl AFTER fuzz/run.jl, so `bridge_run_args`
# (FuzzBridgeArgs) and `WasmTarget` are already in scope. Entry:
# `run_linalg_matrix_tests()` (asserts via @test; skips cleanly without Node).

using LinearAlgebra
using Random
using Test

const _LA_B = WasmTarget.Bridge

# Run `fn` over `inputs` (vector of arg-tuples), oracle-compare wasm vs native.
# `true` iff every input matches (native-throw ⇒ wasm-trap parity).
function _la_diff(fn, argTs::Tuple, inputs::Vector, rettype)
    res = bridge_run_args(fn, argTs, inputs; rettype = rettype)
    res isa Vector || return false
    rdesc = _LA_B.descriptor(rettype)[1]
    for (i, r) in enumerate(res)
        a = inputs[i]
        nat = try (true, fn(a...)) catch; (false, nothing) end
        ok = r[1] === :ok ? (nat[1] && _LA_B.tree_matches(rdesc, nat[2], r[2])) : !nat[1]
        ok || return false
    end
    return true
end

# deterministic generators
_rmat(rng, r, c) = Float64[2 * rand(rng) - 1 for _ in 1:r, _ in 1:c]
_rvec(rng, n)    = Float64[2 * rand(rng) - 1 for _ in 1:n]
# diagonally-dominant square (well-conditioned, invertible, stable det)
function _rdsq(rng, n)
    A = _rmat(rng, n, n)
    @inbounds for i in 1:n; A[i, i] += n; end
    A
end
# symmetric positive-definite (logdet/cholesky need det > 0)
function _rspd(rng, n)
    M = _rmat(rng, n, n)
    M * M' + n * Matrix{Float64}(I, n, n)
end

const _MF = Matrix{Float64}
const _VF = Vector{Float64}

# named op wrappers (so each op is a CALLEE — overlays apply)
_la_copy(m)  = copy(m)
_la_pdims(m) = permutedims(m)
_la_triu(m)  = triu(m)
_la_tril(m)  = tril(m)
_la_kron(a, b) = kron(a, b)
_la_diagm(v) = diagm(v)
_la_add(a, b) = a + b
_la_sub(a, b) = a - b
_la_mm(a, b)  = a * b
_la_mv(m, v)  = m * v
_la_diagf(m) = diag(m)
_la_tr(m)    = tr(m)
_la_opn1(m)  = opnorm(m, 1)
_la_opninf(m)= opnorm(m, Inf)
_la_normf(m) = norm(m)
_la_issym(m) = issymmetric(m)
_la_isherm(m)= ishermitian(m)
_la_isdiag(m)= isdiag(m)
_la_istriu(m)= istriu(m)
_la_istril(m)= istril(m)
_la_det(m)   = det(m)
_la_logdet(m)= logdet(m)
_la_inv(m)   = inv(m)
_la_solve(A, b) = A \ b

function run_linalg_matrix_tests(; reps::Int = 40)
    FuzzHarness.NODE_OK || (@test_skip true; return)
    rng = MersenneTwister(0x1AA0)
    sq   = [ (n = rand(rng, 2:4); (_rmat(rng, n, n),)) for _ in 1:reps ]
    rect = [ (r = rand(rng, 2:4); c = rand(rng, 2:4); (_rmat(rng, r, c),)) for _ in 1:reps ]
    vins = [ (n = rand(rng, 2:5); (_rvec(rng, n),)) for _ in 1:reps ]
    small= [ (n = rand(rng, 2:3); m = _rmat(rng, n, n); (m, m)) for _ in 1:reps ]
    psum = [ (n = rand(rng, 2:4); (_rmat(rng, n, n), _rmat(rng, n, n))) for _ in 1:reps ]
    pmm  = [ (p = rand(rng, 2:4); q = rand(rng, 2:4); s = rand(rng, 2:4);
             (_rmat(rng, p, q), _rmat(rng, q, s))) for _ in 1:reps ]
    pmv  = [ (p = rand(rng, 2:4); q = rand(rng, 2:4); (_rmat(rng, p, q), _rvec(rng, q))) for _ in 1:reps ]
    dsq  = [ (n = rand(rng, 2:4); (_rdsq(rng, n),)) for _ in 1:reps ]
    sspd = [ (n = rand(rng, 2:4); (_rspd(rng, n),)) for _ in 1:reps ]
    sbv  = [ (n = rand(rng, 2:4); (_rdsq(rng, n), _rvec(rng, n))) for _ in 1:reps ]

    @testset "matrix → matrix" begin
        @test _la_diff(_la_copy,  (_MF,),     rect,  _MF)
        @test _la_diff(_la_pdims, (_MF,),     rect,  _MF)
        @test _la_diff(_la_triu,  (_MF,),     sq,    _MF)
        @test _la_diff(_la_tril,  (_MF,),     sq,    _MF)
        @test _la_diff(_la_kron,  (_MF, _MF), small, _MF)
        @test _la_diff(_la_diagm, (_VF,),     vins,  _MF)
        @test _la_diff(_la_add,   (_MF, _MF), psum,  _MF)
        @test _la_diff(_la_sub,   (_MF, _MF), psum,  _MF)
    end
    @testset "matmul (ext overlay → textbook product)" begin
        @test _la_diff(_la_mm, (_MF, _MF), pmm, _MF)   # matrix * matrix
        @test _la_diff(_la_mv, (_MF, _VF), pmv, _VF)   # matrix * vector
    end
    @testset "matrix → vector / scalar" begin
        @test _la_diff(_la_diagf,  (_MF,), sq,   _VF)
        @test _la_diff(_la_tr,     (_MF,), sq,   Float64)
        @test _la_diff(_la_opn1,   (_MF,), sq,   Float64)
        @test _la_diff(_la_opninf, (_MF,), sq,   Float64)
        @test _la_diff(_la_normf,  (_MF,), rect, Float64)   # Frobenius
    end
    @testset "matrix → bool predicates" begin
        @test _la_diff(_la_issym,  (_MF,), sq, Bool)
        @test _la_diff(_la_isherm, (_MF,), sq, Bool)
        @test _la_diff(_la_isdiag, (_MF,), sq, Bool)
        @test _la_diff(_la_istriu, (_MF,), sq, Bool)
        @test _la_diff(_la_istril, (_MF,), sq, Bool)
    end
    @testset "factorizations (ext overlay → generic LU)" begin
        @test _la_diff(_la_det,    (_MF,), dsq,  Float64)   # diagonally-dominant
        @test _la_diff(_la_logdet, (_MF,), sspd, Float64)   # SPD ⇒ det>0
    end
    @testset "decompositions (hand-rolled, Float64)" begin
        @test _la_diff(_la_inv,    (_MF,),      dsq, _MF)        # LU + substitution
        @test _la_diff(_la_solve,  (_MF, _VF),  sbv, _VF)        # LU solve
    end
end
