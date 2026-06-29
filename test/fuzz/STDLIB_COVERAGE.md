# Stdlib Coverage — per-stdlib support, grounded in differential tests

Regenerate: `julia --project=test/fuzz test/fuzz/stdlib_coverage.jl`

`supported` = has a real differential test (catalogue entry the stochastic
fuzzer composes+diffs, OR a `linalg_diff.jl` sweep — same bit-exact/tolerance
oracle as core). `boundary` = in-scope, not yet verified. `out-of-scope` =
genuinely non-wasm (BLAS/LAPACK ccall plumbing, threads/timing, I/O).

**% support = supported / (supported + boundary)** — i.e. of the in-scope
surface (out-of-scope excluded). Types listed separately.

## LinearAlgebra — 97% of in-scope functions supported

Matrix + factorization + structured-type surface verified by test/fuzz/linalg_diff.jl (90+ differential sweeps): values (det/inv/\/svdvals/eigvals/...), OBJECTS (lu/cholesky/eigen/svd via hand-rolled LU/Jacobi/one-sided-Jacobi, reconstruction-verified), pinv, in-place (mul!/triu!/tril!/lmul!/rmul!/axpy!/axpby!/normalize!). ≥95% campaign added: operators ⋅/×/\, lowercase lazy wrappers symmetric/hermitian, in-place copies/fills copyto!/copytrito!/fillstored!/copy_transpose!/copy_adjoint!, Givens rotate!/reflect!, kron!, isbanded, and triangular-solve/symmetrize overlays ldiv!/rdiv!/hermitianpart!. CAN'T (codegen wall, see out-of-scope): qr/schur/lq/hessenberg/bunchkaufman/ldlt packed forms, in-place LAPACK !-variants, general/complex eigen, sylvester/lyap. BOUNDARY (deferred): `/` (general matrix right-division) and `convert` (generic, weak to claim).

Functions: **62 supported**, 2 boundary, 42 out-of-scope (106 total). Types: 5/41 with verified construction/ops.

| function | status |
|---|---|
| `\` | ✅ supported |
| `adjoint` | ✅ supported |
| `adjoint!` | ✅ supported |
| `axpby!` | ✅ supported |
| `axpy!` | ✅ supported |
| `checksquare` | ✅ supported |
| `cholesky` | ✅ supported |
| `cond` | ✅ supported |
| `condskeel` | ✅ supported |
| `copy_adjoint!` | ✅ supported |
| `copy_transpose!` | ✅ supported |
| `copyto!` | ✅ supported |
| `copytrito!` | ✅ supported |
| `cross` | ✅ supported |
| `det` | ✅ supported |
| `diag` | ✅ supported |
| `diagm` | ✅ supported |
| `dot` | ✅ supported |
| `eigen` | ✅ supported |
| `eigmax` | ✅ supported |
| `eigmin` | ✅ supported |
| `eigvals` | ✅ supported |
| `fillstored!` | ✅ supported |
| `hermitian` | ✅ supported |
| `hermitianpart` | ✅ supported |
| `hermitianpart!` | ✅ supported |
| `isbanded` | ✅ supported |
| `isdiag` | ✅ supported |
| `ishermitian` | ✅ supported |
| `issymmetric` | ✅ supported |
| `istril` | ✅ supported |
| `istriu` | ✅ supported |
| `kron` | ✅ supported |
| `kron!` | ✅ supported |
| `ldiv!` | ✅ supported |
| `lmul!` | ✅ supported |
| `logabsdet` | ✅ supported |
| `logdet` | ✅ supported |
| `lu` | ✅ supported |
| `mul!` | ✅ supported |
| `norm` | ✅ supported |
| `normalize` | ✅ supported |
| `normalize!` | ✅ supported |
| `opnorm` | ✅ supported |
| `pinv` | ✅ supported |
| `rank` | ✅ supported |
| `rdiv!` | ✅ supported |
| `reflect!` | ✅ supported |
| `rmul!` | ✅ supported |
| `rotate!` | ✅ supported |
| `svd` | ✅ supported |
| `svdvals` | ✅ supported |
| `symmetric` | ✅ supported |
| `tr` | ✅ supported |
| `transpose` | ✅ supported |
| `transpose!` | ✅ supported |
| `tril` | ✅ supported |
| `tril!` | ✅ supported |
| `triu` | ✅ supported |
| `triu!` | ✅ supported |
| `×` | ✅ supported |
| `⋅` | ✅ supported |
| `/` | ⛔ boundary |
| `bunchkaufman` | ▽ out-of-scope |
| `bunchkaufman!` | ▽ out-of-scope |
| `cholesky!` | ▽ out-of-scope |
| `convert` | ⛔ boundary |
| `diagind` | ▽ out-of-scope |
| `diagview` | ▽ out-of-scope |
| `eigen!` | ▽ out-of-scope |
| `eigvals!` | ▽ out-of-scope |
| `eigvecs` | ▽ out-of-scope |
| `factorize` | ▽ out-of-scope |
| `givens` | ▽ out-of-scope |
| `haszero` | ▽ out-of-scope |
| `hermitian_type` | ▽ out-of-scope |
| `hessenberg` | ▽ out-of-scope |
| `hessenberg!` | ▽ out-of-scope |
| `inertia` | ▽ out-of-scope |
| `isposdef` | ▽ out-of-scope |
| `isposdef!` | ▽ out-of-scope |
| `issuccess` | ▽ out-of-scope |
| `ldlt` | ▽ out-of-scope |
| `ldlt!` | ▽ out-of-scope |
| `lowrankdowndate` | ▽ out-of-scope |
| `lowrankdowndate!` | ▽ out-of-scope |
| `lowrankupdate` | ▽ out-of-scope |
| `lowrankupdate!` | ▽ out-of-scope |
| `lq` | ▽ out-of-scope |
| `lq!` | ▽ out-of-scope |
| `lu!` | ▽ out-of-scope |
| `lyap` | ▽ out-of-scope |
| `matprod_dest` | ▽ out-of-scope |
| `nullspace` | ▽ out-of-scope |
| `ordschur` | ▽ out-of-scope |
| `ordschur!` | ▽ out-of-scope |
| `peakflops` | ▽ out-of-scope |
| `qr` | ▽ out-of-scope |
| `qr!` | ▽ out-of-scope |
| `schur` | ▽ out-of-scope |
| `schur!` | ▽ out-of-scope |
| `svd!` | ▽ out-of-scope |
| `svdvals!` | ▽ out-of-scope |
| `sylvester` | ▽ out-of-scope |
| `symmetric_type` | ▽ out-of-scope |
| `zeroslike` | ▽ out-of-scope |

**Types** (5/41 with verified ops): 
`AbstractTriangular`, `Adjoint`, `Bidiagonal`, `BunchKaufman`, `Cholesky`, `CholeskyPivoted`, `ColumnNorm`, `Diagonal`✅, `Eigen`, `Factorization`, `GeneralizedEigen`, `GeneralizedSVD`, `GeneralizedSchur`, `Givens`, `Hermitian`✅, `Hessenberg`, `LAPACKException`, `LDLt`, `LQ`, `LU`, `LowerTriangular`✅, `NoPivot`, `PosDefException`, `QR`, `QRPivoted`, `RankDeficientException`, `RowMaximum`, `RowNonZero`, `SVD`, `Schur`, `SingularException`, `SymTridiagonal`, `Symmetric`✅, `Transpose`, `Tridiagonal`, `UniformScaling`, `UnitLowerTriangular`, `UnitUpperTriangular`, `UpperHessenberg`, `UpperTriangular`✅, `ZeroPivotException`


## Statistics — 100% of in-scope functions supported

Non-! surface fuzzed by the catalogue (mod=:stats; stochastic compose+diff); in-place mean!/median!/quantile! by test/fuzz/stats_diff.jl (mean! via a row-means ext overlay).

Functions: **13 supported**, 0 boundary, 0 out-of-scope (13 total). Types: 0/0 with verified construction/ops.

| function | status |
|---|---|
| `cor` | ✅ supported |
| `cov` | ✅ supported |
| `mean` | ✅ supported |
| `mean!` | ✅ supported |
| `median` | ✅ supported |
| `median!` | ✅ supported |
| `middle` | ✅ supported |
| `quantile` | ✅ supported |
| `quantile!` | ✅ supported |
| `std` | ✅ supported |
| `stdm` | ✅ supported |
| `var` | ✅ supported |
| `varm` | ✅ supported |

## Dates — 96% of in-scope functions supported

Value layer differentially fuzzed by test/fuzz/dates_diff.jl: accessors, Date↔Date adjusters, arithmetic, construction (Date/DateTime/Time), epoch+calendar conversions (datetime2unix/unix2datetime/datetime2julian/julian2datetime/datetime2rata/rata2datetime — pure arithmetic, both directions), multi-field tuple extractors (yearmonthday/yearmonth/monthday), Time sub-second accessors (microsecond/nanosecond), locale names (dayname/dayabbr/monthname/monthabbr via ENGLISH-table ext overlays), and day-of-week adjusters (tofirst/tolast/tonext/toprev via modular-arithmetic ext overlays). now()/today() need host wall-clock (embedding import). BOUNDARY (deferred, not yet verified): format (the DateFormat token-DSL engine) and canonicalize (CompoundPeriod normalization — a Method-as-value the generator can't yet compile).

Functions: **45 supported**, 2 boundary, 2 out-of-scope (49 total). Types: 10/21 with verified construction/ops.

| function | status |
|---|---|
| `datetime2julian` | ✅ supported |
| `datetime2rata` | ✅ supported |
| `datetime2unix` | ✅ supported |
| `day` | ✅ supported |
| `dayabbr` | ✅ supported |
| `dayname` | ✅ supported |
| `dayofmonth` | ✅ supported |
| `dayofquarter` | ✅ supported |
| `dayofweek` | ✅ supported |
| `dayofweekofmonth` | ✅ supported |
| `dayofyear` | ✅ supported |
| `daysinmonth` | ✅ supported |
| `daysinyear` | ✅ supported |
| `daysofweekinmonth` | ✅ supported |
| `firstdayofmonth` | ✅ supported |
| `firstdayofquarter` | ✅ supported |
| `firstdayofweek` | ✅ supported |
| `firstdayofyear` | ✅ supported |
| `hour` | ✅ supported |
| `isleapyear` | ✅ supported |
| `julian2datetime` | ✅ supported |
| `lastdayofmonth` | ✅ supported |
| `lastdayofquarter` | ✅ supported |
| `lastdayofweek` | ✅ supported |
| `lastdayofyear` | ✅ supported |
| `microsecond` | ✅ supported |
| `millisecond` | ✅ supported |
| `minute` | ✅ supported |
| `month` | ✅ supported |
| `monthabbr` | ✅ supported |
| `monthday` | ✅ supported |
| `monthname` | ✅ supported |
| `nanosecond` | ✅ supported |
| `quarterofyear` | ✅ supported |
| `rata2datetime` | ✅ supported |
| `second` | ✅ supported |
| `tofirst` | ✅ supported |
| `tolast` | ✅ supported |
| `tonext` | ✅ supported |
| `toprev` | ✅ supported |
| `unix2datetime` | ✅ supported |
| `week` | ✅ supported |
| `year` | ✅ supported |
| `yearmonth` | ✅ supported |
| `yearmonthday` | ✅ supported |
| `canonicalize` | ⛔ boundary |
| `format` | ⛔ boundary |
| `now` | ▽ out-of-scope |
| `today` | ▽ out-of-scope |

**Types** (10/21 with verified ops): 
`Date`✅, `DateFormat`, `DatePeriod`, `DateTime`✅, `Day`✅, `Hour`✅, `Microsecond`, `Millisecond`, `Minute`✅, `Month`✅, `Nanosecond`, `Period`, `Quarter`, `Second`✅, `Time`✅, `TimePeriod`, `TimeType`, `TimeZone`, `UTC`, `Week`✅, `Year`✅


## Random — 100% of in-scope functions supported

Seeded Xoshiro streams differentially fuzzed by test/fuzz/random_diff.jl on Julia ≤1.12: rand/randn/randexp (scalar), randperm/randcycle/shuffle & their `!`-variants, seed!, randsubseq/randsubseq!, randstring (ext overlay via native's OWN collection bulk fill). NB rand/randn are Base-owned (not in names(Random)) so they don't count below, but ARE verified. VERSION CAVEAT: the ENTIRE seeded-Xoshiro differential is gated to ≤1.12 — on Julia 1.13-rc1 it is broadly UNRELIABLE (CI shows flaky wasm↔native divergences across all seeded streams, even basic rand(Xoshiro(s)), and across platforms; 1.13 reworked Xoshiro seeding via a new SeedHasher path the differential can't reproduce stably). So RANDOM_VERIFIED is empty on ≥1.13 and this % is a ≤1.12 measurement (the stable release the campaign targets); the 1.13-rc1 instability is logged in FINDINGS as a soundness-loop candidate. CAN'T (all versions): rand!/randn!/randexp! Float64-array fills route through an 8-lane SIMD bulk generator (llvmcall intrinsics; stream ≠ scalar for n≥8); bitrand (BitVector packed bits); default_rng/RandomDevice (host entropy); MersenneTwister state hits a codegen gap.

Functions: **11 supported**, 0 boundary, 5 out-of-scope (16 total). Types: 1/9 with verified construction/ops.

| function | status |
|---|---|
| `randcycle` | ✅ supported |
| `randcycle!` | ✅ supported |
| `randexp` | ✅ supported |
| `randperm` | ✅ supported |
| `randperm!` | ✅ supported |
| `randstring` | ✅ supported |
| `randsubseq` | ✅ supported |
| `randsubseq!` | ✅ supported |
| `seed!` | ✅ supported |
| `shuffle` | ✅ supported |
| `shuffle!` | ✅ supported |
| `bitrand` | ▽ out-of-scope |
| `default_rng` | ▽ out-of-scope |
| `rand!` | ▽ out-of-scope |
| `randexp!` | ▽ out-of-scope |
| `randn!` | ▽ out-of-scope |

**Types** (1/9 with verified ops): 
`AbstractRNG`, `MersenneTwister`, `RandomDevice`, `Sampler`, `SamplerSimple`, `SamplerTrivial`, `SamplerType`, `TaskLocalRNG`, `Xoshiro`✅


## SparseArrays — 100% of in-scope functions supported

Differentially fuzzed by test/fuzz/sparse_diff.jl (each name = a wasm-vs-native sweep over randomized sparse inputs, same oracle as core). Construction `sparse(::Matrix)` + read/reduce/matvec (nnz/issparse/nonzeros/rowvals/sum/maximum/sparse·vector/sparse·dense) via 2 ext overlays (sparse_check_Ti + hand-rolled dense→CSC). RESULT ops via an ELEGANT core+ext pair — a narrow `is_struct_type` carve-out (register SparseMatrixCSC as its real 5-field struct, not WT's 2-field array layout) + an outer-ctor overlay (route to the concrete inner ctor, sidestepping a runtime `apply_type` WT mis-lowers): unlocks matmul/scalar·sparse/copy. Per-op CSC overlays: transpose, spdiagm, hcat/vcat (+ sparse_hcat/sparse_vcat), blockdiag, permute. Plus findnz/droptol!/dropzeros!/sparsevec/nzrange/spzeros/fkeep!/ftranspose!/sparse_hvcat direct, and sparse `+`/`-` (Base operators — not in this names-%, but differentially verified: a dense-accumulator merge after the two-pointer `while` version exposed a WT loop-codegen bug, see FINDINGS). MULTI-OP COMBOS also fuzzed (A*B+Cᵀ, dropzeros(A-B), 2A+B*B, nnz(A+B), blockdiag(A,A*B)ᵀ, …) so the ops are proven to compose, not just work in isolation. CAN'T: ``/factorizations (SuiteSparse C library); sprand/sprandn (RNG consumption diverges wasm↔native, same class as the Random SIMD fills).

Functions: **20 supported**, 0 boundary, 2 out-of-scope (22 total). Types: 0/5 with verified construction/ops.

| function | status |
|---|---|
| `blockdiag` | ✅ supported |
| `droptol!` | ✅ supported |
| `dropzeros` | ✅ supported |
| `dropzeros!` | ✅ supported |
| `findnz` | ✅ supported |
| `fkeep!` | ✅ supported |
| `ftranspose!` | ✅ supported |
| `issparse` | ✅ supported |
| `nnz` | ✅ supported |
| `nonzeros` | ✅ supported |
| `nzrange` | ✅ supported |
| `permute` | ✅ supported |
| `rowvals` | ✅ supported |
| `sparse` | ✅ supported |
| `sparse_hcat` | ✅ supported |
| `sparse_hvcat` | ✅ supported |
| `sparse_vcat` | ✅ supported |
| `sparsevec` | ✅ supported |
| `spdiagm` | ✅ supported |
| `spzeros` | ✅ supported |
| `sprand` | ▽ out-of-scope |
| `sprandn` | ▽ out-of-scope |

**Types** (0/5 with verified ops): 
`AbstractSparseArray`, `AbstractSparseMatrix`, `AbstractSparseVector`, `SparseMatrixCSC`, `SparseVector`


## ForwardDiff — 100% of in-scope functions supported

FIRST SciML library. Forward-mode autodiff in the browser — EXACT derivatives, no host, no finite differences. `names(ForwardDiff)` is empty (the API is qualified-access only), so the surface below is ForwardDiff's documented public AD operations, each a wasm-vs-native differential sweep in test/fuzz/forwarddiff_diff.jl. `derivative` compiles straight from the real impl (single-partial `Dual` seed). `gradient`/`jacobian`/`hessian` (+ the in-place `!` forms) are ext overlays: native routes them through the chunk/`Config` machinery, which embeds a cyclic `Method` constant WT can't emit — so we reuse the working single-partial `Dual` seed one input direction at a time (Partials{1} × N), BIT-IDENTICAL to native's Partials{N} vector mode (forward-mode partials never cross slots); `hessian` is forward-over-forward with two distinct tags. The whole value path is unlocked by a narrow `is_struct_type` carve-out (src/codegen/structs.jl) registering `Dual`/`Partials` as their real structs — without it `<:Number` routes them to `structref` and a `Dual[…]` array literal fails wasm validation (a systemic core fix: every custom `<:Number` struct benefits). The `Dual` number interface (value/partials) is exercised in every sweep; COMBOS verified too (‖∇f‖, J·x, a hand 2×2 Newton step J⁻¹F, gradient through a named helper). OUT-OF-SCOPE: the `GradientConfig`/`JacobianConfig`/`HessianConfig`/`Chunk` preallocation API (advanced chunk-size tuning — the cyclic-`Method` `@generated` seeder; unnecessary, the standard API covers the same results).

Functions: **8 supported**, 0 boundary, 0 out-of-scope (8 total). Types: 0/0 with verified construction/ops.

| function | status |
|---|---|
| `derivative` | ✅ supported |
| `derivative!` | ✅ supported |
| `gradient` | ✅ supported |
| `gradient!` | ✅ supported |
| `hessian` | ✅ supported |
| `hessian!` | ✅ supported |
| `jacobian` | ✅ supported |
| `jacobian!` | ✅ supported |

## StaticArrays — 100% of in-scope functions supported

StaticArrays SUPPORT for the 1-D `SVector` surface — the static vector type the SciML ecosystem builds on (SimpleDiffEq's SimpleTsit5 Butcher tableau, static-vector ODE state). `SVector{N,T} === SArray{Tuple{N},T,1,N}` is NOT a heap array but a struct over a single `NTuple{L,T}` field; two fixes in ext/WasmTargetStaticArraysExt.jl unlock the whole value path: (1) register `:SArray` in the `is_struct_type` carve-out (src/codegen/structs.jl) so WT lays it out as the concrete NTuple-backed struct it is, not the generic 2-field array layout (the SparseMatrixCSC / ForwardDiff-Dual lever); (2) overlay `StaticArrays.construct_type` for an already-parameterized `SArray` to the identity — native folds construct_type's pure type-level machinery (adapt_size/adapt_eltype/typeintersect/has_size) to the concrete `Type{SVector{N,T}}`, but WT's interpreter (concrete-eval disabled to protect overlays) infers `Any`, boxing the whole SVector and every getindex off it. Each operation is a wasm-vs-native differential sweep in test/fuzz/staticarrays_diff.jl: construction (positional / single-Tuple / converting-eltype, ALL N≥1 including the degenerate single-element vector), getindex, iterate/destructure/for-loop, reductions (sum/prod/maximum/minimum), arithmetic (+/-/scalar-*), dot, broadcast, and Vector output via collect. OUT-OF-SCOPE (this round): SMatrix / MArray / MVector / SizedArray (2-D + mutable static arrays — a distinct @generated codegen surface).

Functions: **10 supported**, 0 boundary, 0 out-of-scope (10 total). Types: 0/0 with verified construction/ops.

| function | status |
|---|---|
| `SArray` | ✅ supported |
| `SVector` | ✅ supported |
| `broadcast` | ✅ supported |
| `dot` | ✅ supported |
| `getindex` | ✅ supported |
| `iterate` | ✅ supported |
| `length` | ✅ supported |
| `map` | ✅ supported |
| `prod` | ✅ supported |
| `sum` | ✅ supported |

## SimpleDiffEq — 100% of in-scope functions supported

SimpleDiffEq (+ SciMLBase / DiffEqBase) — solve ordinary differential equations INSIDE a frozen wasm module, no host, no Julia runtime. Every FIXED-STEP solver — SimpleEuler, SimpleRK4, SimpleTsit5, LoopEuler, LoopRK4 — is a wasm-vs-native differential sweep in test/fuzz/simplediffeq_diff.jl over scalar (decay/logistic), Vector-state (harmonic oscillator / Lotka–Volterra / nonlinear pendulum) AND SVector-state ODEs (NOTHING DROPPED — SimpleTsit5's Butcher tableau lives in SVector{6/21/22} caches, unblocked by the StaticArrays support above). The wall is the SciMLBase ABSTRACTION the user touches; three pure levers clear it: (1) a curated type-level concrete-eval fold (src/codegen/interpreter.jl) re-enables folding for apply_type/_compute_sparams/eltype/isinplace-type-param/… so ODEProblem/ODEFunction construction infers concretely instead of `Any`; (2) an `ODEProblem(f,u0,tspan)` overlay builds the ODEFunction CONCRETELY, bypassing the `isinplace` method-arity reflection on a raw function; (3) a `solve(prob, alg; dt)` overlay calls `DiffEqBase.__solve` directly, bypassing the runtime kwarg-Pairs machinery. The SciML solution types (ODESolution/LinearInterpolation/DiffEqArray/VectorOfArray) are registered in the is_struct_type carve-out so `sol.u`/`sol.t` are reachable, not dynamic. OUT-OF-SCOPE: adaptive solvers (SimpleATsit5 — error-control + dense interpolation), GPU solvers, callbacks/events (root-finding).

Functions: **8 supported**, 0 boundary, 0 out-of-scope (8 total). Types: 0/0 with verified construction/ops.

| function | status |
|---|---|
| `LoopEuler` | ✅ supported |
| `LoopRK4` | ✅ supported |
| `ODEFunction` | ✅ supported |
| `ODEProblem` | ✅ supported |
| `SimpleEuler` | ✅ supported |
| `SimpleRK4` | ✅ supported |
| `SimpleTsit5` | ✅ supported |
| `solve` | ✅ supported |

## Summary

| stdlib | % in-scope supported | supported | boundary | out-of-scope |
|---|---|---|---|---|
| LinearAlgebra | **97%** | 62 | 2 | 42 |
| Statistics | **100%** | 13 | 0 | 0 |
| Dates | **96%** | 45 | 2 | 2 |
| Random | **100%** | 11 | 0 | 5 |
| SparseArrays | **100%** | 20 | 0 | 2 |
| ForwardDiff | **100%** | 8 | 0 | 0 |
| StaticArrays | **100%** | 10 | 0 | 0 |
| SimpleDiffEq | **100%** | 8 | 0 | 0 |
