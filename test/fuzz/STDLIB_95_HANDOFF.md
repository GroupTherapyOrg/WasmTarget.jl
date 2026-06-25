# Stdlib ≥95% Campaign — Handoff (survives compaction)

**Mission (Dale, 2026-06-25, autonomous/overnight):** drive EVERY currently-supported
stdlib to **≥95% in-scope support** in `STDLIB_COVERAGE.md`. Do NOT settle for the
current numbers — go through each stdlib's `boundary` list ONE BY ONE and either
(a) genuinely FUZZ it (add a differential sweep — same oracle as core), or
(b) reclassify it OUT-OF-SCOPE **only if genuine CAN'T, with a documented reason**.
Never reclassify a tractable item just to game the %. Branch = `wt-stdlib-linalg`
(off `main`, ~18 commits). Commit per stdlib when it crosses ≥95%.

## Current scorecard (regenerate to refresh)
`julia --project=test/fuzz test/fuzz/stdlib_coverage.jl`  → STDLIB_COVERAGE.md
- LinearAlgebra **70%** (45 sup / 19 boundary / 42 oos)
- Statistics **77%** (10 / 3 / 0)
- Dates **57%** (26 / 20 / 3)
- Random **25%** (4 / 12 / 0 — rand/randn verified but Base-owned, not counted)
% = supported / (supported + boundary). out-of-scope (genuine CAN'T) is excluded.

## The apparatus (how "supported" is grounded)
- `test/fuzz/stdlib_coverage.jl` → `STDLIB_COVERAGE.md`: enumerates `names(Stdlib)`,
  classifies each via `SPECS` (verified set ∪ out-of-scope set), computes %.
- Per-stdlib differential fuzzers (for value types the catalogue generator can't
  produce), each EXPORTING its verified-name set; wired into `fuzz_suite.jl` (CI):
  - `linalg_diff.jl` → `LINALG_VERIFIED` (65 sweeps)
  - `dates_diff.jl`  → `DATES_VERIFIED` (39 sweeps)
  - `random_diff.jl` → `RANDOM_VERIFIED` (12 sweeps)
- Catalogue (`catalogue.jl` mod=:stats/:dates/:linalg) = stochastically fuzzed by
  the generator for scalar/vector ops (Statistics fully here).

## The loop (per boundary item)
1. PROBE it via a throwaway `/tmp/probe_X.jl` (warm, ~25s) — copy the `chk`
   pattern from probe_inplace.jl / probe_dates2.jl: `bridge_run_args(fn, argTs,
   inputs; rettype)` then `B.tree_matches`. Wrap the fn in a NAMED function (callee
   context — overlays apply to callees, not the bare entry).
2. OK → add it to the stdlib's `*_diff.jl` (wrapper + @test) AND its `*_VERIFIED`
   set. MISMATCH/SETUP → either write an ext overlay (hand-rolled, see recipe) or
   reclassify out-of-scope in `stdlib_coverage.jl`'s SPEC with a reason comment.
3. Validate the `*_diff.jl` standalone (warm): `julia --project=test/fuzz
   /tmp/run_<x>_test.jl` (see existing run_*_test.jl drivers).
4. Regenerate the report; when the stdlib ≥95%, gate `julia --project=. -e 'using
   Pkg; Pkg.test()'` (confirm "Differential fuzz: …" lines + "tests passed") and
   COMMIT (standard trailer). loop_guard.sh on catalogue edits.

## Boundary work-lists (probe each)
- **Statistics (3):** median!, quantile! (in-place, sort the vector — add to
  catalogue with mutates=true), mean! (dest+dims — assess).
- **Random (12):** in-place rand!/randn!/randexp!/randperm!/randcycle!/shuffle!/
  randsubseq! (mutate a buffer — return it), randsubseq (prob arg), randstring
  (mismatched — char encoding; investigate or oos), bitrand (BitVector — bridge?),
  seed! (mutates RNG), default_rng (host → oos), Sampler (internal → oos).
- **Dates (20):** conversions datetime2unix/unix2datetime/datetime2julian/
  julian2datetime/datetime2rata/rata2datetime; parse/format Date(str)/DateTime(str)/
  parse/format; names dayname/monthname/dayabbr/monthabbr (locale — may oos);
  adjusters tonext/toprev/tofirst/tolast; canonicalize; Dates.value; Period ops.
- **LinearAlgebra (19):** ldiv!/rdiv! (in-place solve — overlay via my lu_solve),
  kron! (in-place), symmetric/hermitian (constructors), copytrito!/copy_adjoint!/
  copy_transpose! (triangle copies), fillstored!, hermitianpart! (in-place),
  isbanded. Stretch: qr via modified Gram-Schmidt → QR object (reconstruction-
  verified) to move qr out of oos.

## Proven recipe (the reusable technique)
LAPACK/BLAS-backed fn WT can't lower → ext overlay (`WasmTargetLinearAlgebraExt.jl`)
with a HAND-ROLLED textbook algorithm (LU+substitution, cyclic Jacobi eigen,
one-sided Jacobi SVD), Float64-only, verified under the rtol-1e-9 oracle. KWARG-
dispatched fns (eigvals/lu/cholesky/svd/eigen): write the overlay WITH the kwarg
signature to intercept. Factorization OBJECTS with explicit factors (lu/cholesky/
eigen/svd) ship via object + downstream overlays, vectors verified by
RECONSTRUCTION (sign/order-invariant). In-place ops: write the result into the
buffer + return it; test compares the return (= mutated buffer). See memory
`wt-genericlinearalgebra-overlay-lever` for the full recipe + state.

## Genuine CAN'T already documented (don't re-chase)
LAPACK-packed factorizations (qr/lq/schur/hessenberg/bunchkaufman/ldlt + objects +
in-place !-variants lu!/svd!/eigen!/cholesky!/eigvals!), general/complex eigen
(Jacobi is symmetric-only — QR-iteration hits the codegen wall), sylvester/lyap
(need Schur), nullspace (ambiguous basis), isposdef (cholesky LAPACK check),
host wall-clock (now/today), OS entropy (RandomDevice, MersenneTwister state),
peakflops, BLAS/LAPACK submodules, internal type-computers.
