# Stdlib Coverage — per-stdlib support, grounded in differential tests

Regenerate: `julia --project=test/fuzz test/fuzz/stdlib_coverage.jl`

`supported` = has a real differential test (catalogue entry the stochastic
fuzzer composes+diffs, OR a `linalg_diff.jl` sweep — same bit-exact/tolerance
oracle as core). `boundary` = in-scope, not yet verified. `out-of-scope` =
genuinely non-wasm (BLAS/LAPACK ccall plumbing, threads/timing, I/O).

**% support = supported / (supported + boundary)** — i.e. of the in-scope
surface (out-of-scope excluded). Types listed separately.

## LinearAlgebra — 70% of in-scope functions supported

Matrix + factorization + structured-type surface verified by test/fuzz/linalg_diff.jl (61 differential sweeps): values (det/inv/\/svdvals/eigvals/...), OBJECTS (lu/cholesky/eigen/svd via hand-rolled LU/Jacobi/one-sided-Jacobi, reconstruction-verified), pinv, in-place (mul!/triu!/tril!/lmul!/rmul!/axpy!/axpby!/normalize!), structured types. CAN'T (codegen wall, see out-of-scope): qr/schur/lq/hessenberg/bunchkaufman/ldlt packed forms, in-place LAPACK !-variants, general/complex eigen, sylvester/lyap.

Functions: **45 supported**, 19 boundary, 42 out-of-scope (106 total). Types: 5/41 with verified construction/ops.

| function | status |
|---|---|
| `adjoint` | ✅ supported |
| `adjoint!` | ✅ supported |
| `axpby!` | ✅ supported |
| `axpy!` | ✅ supported |
| `checksquare` | ✅ supported |
| `cholesky` | ✅ supported |
| `cond` | ✅ supported |
| `condskeel` | ✅ supported |
| `cross` | ✅ supported |
| `det` | ✅ supported |
| `diag` | ✅ supported |
| `diagm` | ✅ supported |
| `dot` | ✅ supported |
| `eigen` | ✅ supported |
| `eigmax` | ✅ supported |
| `eigmin` | ✅ supported |
| `eigvals` | ✅ supported |
| `hermitianpart` | ✅ supported |
| `isdiag` | ✅ supported |
| `ishermitian` | ✅ supported |
| `issymmetric` | ✅ supported |
| `istril` | ✅ supported |
| `istriu` | ✅ supported |
| `kron` | ✅ supported |
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
| `rmul!` | ✅ supported |
| `svd` | ✅ supported |
| `svdvals` | ✅ supported |
| `tr` | ✅ supported |
| `transpose` | ✅ supported |
| `transpose!` | ✅ supported |
| `tril` | ✅ supported |
| `tril!` | ✅ supported |
| `triu` | ✅ supported |
| `triu!` | ✅ supported |
| `/` | ⛔ boundary |
| `\` | ⛔ boundary |
| `bunchkaufman` | ▽ out-of-scope |
| `bunchkaufman!` | ▽ out-of-scope |
| `cholesky!` | ▽ out-of-scope |
| `convert` | ⛔ boundary |
| `copy_adjoint!` | ⛔ boundary |
| `copy_transpose!` | ⛔ boundary |
| `copyto!` | ⛔ boundary |
| `copytrito!` | ⛔ boundary |
| `diagind` | ▽ out-of-scope |
| `diagview` | ▽ out-of-scope |
| `eigen!` | ▽ out-of-scope |
| `eigvals!` | ▽ out-of-scope |
| `eigvecs` | ▽ out-of-scope |
| `factorize` | ▽ out-of-scope |
| `fillstored!` | ⛔ boundary |
| `givens` | ▽ out-of-scope |
| `haszero` | ▽ out-of-scope |
| `hermitian` | ⛔ boundary |
| `hermitian_type` | ▽ out-of-scope |
| `hermitianpart!` | ⛔ boundary |
| `hessenberg` | ▽ out-of-scope |
| `hessenberg!` | ▽ out-of-scope |
| `inertia` | ▽ out-of-scope |
| `isbanded` | ⛔ boundary |
| `isposdef` | ▽ out-of-scope |
| `isposdef!` | ▽ out-of-scope |
| `issuccess` | ▽ out-of-scope |
| `kron!` | ⛔ boundary |
| `ldiv!` | ⛔ boundary |
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
| `rdiv!` | ⛔ boundary |
| `reflect!` | ⛔ boundary |
| `rotate!` | ⛔ boundary |
| `schur` | ▽ out-of-scope |
| `schur!` | ▽ out-of-scope |
| `svd!` | ▽ out-of-scope |
| `svdvals!` | ▽ out-of-scope |
| `sylvester` | ▽ out-of-scope |
| `symmetric` | ⛔ boundary |
| `symmetric_type` | ▽ out-of-scope |
| `zeroslike` | ▽ out-of-scope |
| `×` | ⛔ boundary |
| `⋅` | ⛔ boundary |

**Types** (5/41 with verified ops): 
`AbstractTriangular`, `Adjoint`, `Bidiagonal`, `BunchKaufman`, `Cholesky`, `CholeskyPivoted`, `ColumnNorm`, `Diagonal`✅, `Eigen`, `Factorization`, `GeneralizedEigen`, `GeneralizedSVD`, `GeneralizedSchur`, `Givens`, `Hermitian`✅, `Hessenberg`, `LAPACKException`, `LDLt`, `LQ`, `LU`, `LowerTriangular`✅, `NoPivot`, `PosDefException`, `QR`, `QRPivoted`, `RankDeficientException`, `RowMaximum`, `RowNonZero`, `SVD`, `Schur`, `SingularException`, `SymTridiagonal`, `Symmetric`✅, `Transpose`, `Tridiagonal`, `UniformScaling`, `UnitLowerTriangular`, `UnitUpperTriangular`, `UpperHessenberg`, `UpperTriangular`✅, `ZeroPivotException`


## Statistics — 77% of in-scope functions supported

Verified via the catalogue (mod=:stats) — stochastic fuzzer composes + diffs vs native.

Functions: **10 supported**, 3 boundary, 0 out-of-scope (13 total). Types: 0/0 with verified construction/ops.

| function | status |
|---|---|
| `cor` | ✅ supported |
| `cov` | ✅ supported |
| `mean` | ✅ supported |
| `median` | ✅ supported |
| `middle` | ✅ supported |
| `quantile` | ✅ supported |
| `std` | ✅ supported |
| `stdm` | ✅ supported |
| `var` | ✅ supported |
| `varm` | ✅ supported |
| `mean!` | ⛔ boundary |
| `median!` | ⛔ boundary |
| `quantile!` | ⛔ boundary |

## Dates — 57% of in-scope functions supported

Value layer (accessors / adjusters / arithmetic / construction) differentially fuzzed by test/fuzz/dates_diff.jl. now()/today() need host wall-clock (embedding import).

Functions: **26 supported**, 20 boundary, 3 out-of-scope (49 total). Types: 9/21 with verified construction/ops.

| function | status |
|---|---|
| `day` | ✅ supported |
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
| `lastdayofmonth` | ✅ supported |
| `lastdayofquarter` | ✅ supported |
| `lastdayofweek` | ✅ supported |
| `lastdayofyear` | ✅ supported |
| `millisecond` | ✅ supported |
| `minute` | ✅ supported |
| `month` | ✅ supported |
| `quarterofyear` | ✅ supported |
| `second` | ✅ supported |
| `week` | ✅ supported |
| `year` | ✅ supported |
| `canonicalize` | ⛔ boundary |
| `datetime2julian` | ⛔ boundary |
| `datetime2rata` | ⛔ boundary |
| `datetime2unix` | ⛔ boundary |
| `dayabbr` | ⛔ boundary |
| `dayname` | ⛔ boundary |
| `format` | ⛔ boundary |
| `julian2datetime` | ⛔ boundary |
| `microsecond` | ⛔ boundary |
| `monthabbr` | ⛔ boundary |
| `monthday` | ⛔ boundary |
| `monthname` | ⛔ boundary |
| `nanosecond` | ⛔ boundary |
| `now` | ▽ out-of-scope |
| `rata2datetime` | ⛔ boundary |
| `today` | ▽ out-of-scope |
| `tofirst` | ⛔ boundary |
| `tolast` | ⛔ boundary |
| `tonext` | ⛔ boundary |
| `toprev` | ⛔ boundary |
| `unix2datetime` | ▽ out-of-scope |
| `yearmonth` | ⛔ boundary |
| `yearmonthday` | ⛔ boundary |

**Types** (9/21 with verified ops): 
`Date`✅, `DateFormat`, `DatePeriod`, `DateTime`✅, `Day`✅, `Hour`✅, `Microsecond`, `Millisecond`, `Minute`✅, `Month`✅, `Nanosecond`, `Period`, `Quarter`, `Second`✅, `Time`, `TimePeriod`, `TimeType`, `TimeZone`, `UTC`, `Week`✅, `Year`✅


## Random — 25% of in-scope functions supported

Seeded Xoshiro streams differentially fuzzed by test/fuzz/random_diff.jl: rand/randn/randexp/randperm/randcycle/shuffle. NB rand/randn are Base-owned (not in names(Random)) so they don't count below, but ARE verified. CAN'T: RandomDevice/seedless = host entropy (embedding); MersenneTwister state hits a codegen gap; randstring char-encoding differs.

Functions: **4 supported**, 12 boundary, 0 out-of-scope (16 total). Types: 1/9 with verified construction/ops.

| function | status |
|---|---|
| `randcycle` | ✅ supported |
| `randexp` | ✅ supported |
| `randperm` | ✅ supported |
| `shuffle` | ✅ supported |
| `bitrand` | ⛔ boundary |
| `default_rng` | ⛔ boundary |
| `rand!` | ⛔ boundary |
| `randcycle!` | ⛔ boundary |
| `randexp!` | ⛔ boundary |
| `randn!` | ⛔ boundary |
| `randperm!` | ⛔ boundary |
| `randstring` | ⛔ boundary |
| `randsubseq` | ⛔ boundary |
| `randsubseq!` | ⛔ boundary |
| `seed!` | ⛔ boundary |
| `shuffle!` | ⛔ boundary |

**Types** (1/9 with verified ops): 
`AbstractRNG`, `MersenneTwister`, `RandomDevice`, `Sampler`, `SamplerSimple`, `SamplerTrivial`, `SamplerType`, `TaskLocalRNG`, `Xoshiro`✅


## Summary

| stdlib | % in-scope supported | supported | boundary | out-of-scope |
|---|---|---|---|---|
| LinearAlgebra | **70%** | 45 | 19 | 42 |
| Statistics | **77%** | 10 | 3 | 0 |
| Dates | **57%** | 26 | 20 | 3 |
| Random | **25%** | 4 | 12 | 0 |
