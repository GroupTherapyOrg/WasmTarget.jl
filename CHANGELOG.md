# Changelog

## [0.3.0](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.2.1...v0.3.0) (2026-06-11)


### ⚠ BREAKING CHANGES

* ledger at 0 open. Full Pkg.test green.
* 4 closed, 0 still open. Full Pkg.test green.
* 7 closed, 0 still open. Full Pkg.test green.
* 2 closed, 0 still open. Full Pkg.test green.
* 4 closed across the batch, 0 still open. Full Pkg.test green.

### verify_gaps

* 2 closed, 0 still open. Full Pkg.test green. ([12976a2](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/12976a24aa9cb3da464a3a9e5d124de4293850c9))
* 4 closed across the batch, 0 still open. Full Pkg.test green. ([3c1caf4](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/3c1caf4f0e75cb349c4d189acc1aab7b029e98bf))
* 4 closed, 0 still open. Full Pkg.test green. ([7a1d4d1](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/7a1d4d149d54f24d061657d4b4a95f2e248abb68))
* 7 closed, 0 still open. Full Pkg.test green. ([2737229](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/2737229d73d4651f545b6852852fda75482601c4))
* ledger at 0 open. Full Pkg.test green. ([4cf486b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4cf486b2794ebf4b7818fda61da69aa4720863d6))


### Bug Fixes

* branches leaving a compiled block subset now route to an exit block ([12976a2](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/12976a24aa9cb3da464a3a9e5d124de4293850c9))
* byte-level wrap-stripping pass no longer desyncs on GC instructions; ([2737229](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/2737229d73d4651f545b6852852fda75482601c4))
* closures defined in Main now compile when invoked un-inlined; two new ([3c1caf4](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/3c1caf4f0e75cb349c4d189acc1aab7b029e98bf))
* lcm overflow throws catchably; Union{}-containing rettypes recognised ([4cf486b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4cf486b2794ebf4b7818fda61da69aa4720863d6))
* Phase 2 complete — try/catch soundness overhaul, 0 open divergences (batches 21-26) ([ecda643](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/ecda643b8adb250569db2dd72f130feab775d64f))
* try/catch machinery soundness overhaul + zero-divergence coverage matrix ([f8d1054](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/f8d1054fdf7ec2cfe8b934078787a01c8cc17f6c))
* un-inlined always-throwing invokes compile as catchable throws; if/else ([7a1d4d1](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/7a1d4d149d54f24d061657d4b4a95f2e248abb68))

## [0.2.1](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.2.0...v0.2.1) (2026-06-11)


### Features

* promote the fuzz oracle bridge to WasmTarget.Bridge ([27ed4a3](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/27ed4a35a2b0d23067192ea31016b2724b4d1080))
* promote the fuzz oracle bridge to WasmTarget.Bridge ([dca789a](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/dca789a4df78ab54ece25db007916315af9f1142))

## [0.2.0](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.1.1...v0.2.0) (2026-06-10)


### ⚠ BREAKING CHANGES

* strict-by-default soundness + differential combinatorial fuzzer (0.2.0)

### Features

* **fuzz:** add Dict/Set/Char/reduce categories + natural-sig sweep (inventory grows) ([a6ce229](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/a6ce229e8fcc8055c5ff92d731d6ff9dab51b738))
* **fuzz:** coverage metric + collect op ([f9123a4](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/f9123a43ecd3f1241ee42255b18d8a5c1b56c92f))
* **fuzz:** expand generator to ~146 ops + lazy construction for depth ≥4 ([8c86cb7](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/8c86cb79f7399382d88e5c356bfc956abb615ae2))
* **fuzz:** expand generator to vectors/strings/mixed-types + higher-order ops ([53f9d71](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/53f9d71c74a1073e1f6acc8a7dbf5c6e1425d9f0))
* **fuzz:** make generator TYPE-PARAMETRIC over the full lattice (168 → 538 ops) ([115c730](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/115c730a4329f354e17824a0d497864e2efb6cb0))
* **fuzz:** natural-signature fuzzing (Vector args) + depth-4 sweep inventory ([cb1670f](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/cb1670fabecc54d3ea4abb7cd6c12914bfde937e))
* **fuzz:** preserve hand-authored gap analysis across re-records ([3116117](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/311611731839ae94ca48bf5425f63274da13bee7))
* **fuzz:** vector marshalling — test functions in NATURAL signatures ([56c5a89](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/56c5a89c73f9da08ee194bd8298af705f7147223))
* strict-by-default soundness + differential combinatorial fuzzer (0.2.0) ([b2ee465](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/b2ee4654bb219b45a941f7ecd4687a1b32ce7060))


### Bug Fixes

* **codegen:** Julia-semantics integer shift (over-shift guard) ([3faf657](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/3faf6570da081f2e48c5b714346ef930eb4c1f84))
* **fuzz:** harden apparatus — eliminate false positives (mutation aliasing + NaN-vector compare) ([455218b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/455218b66655f30dfd36f4bfeee843ebe16612aa))
* **overlay:** argmax/argmin NaN poisoning (return first NaN index) ([a25dc94](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/a25dc947058949250bbdc5e3982e893d7e79d852))
* **overlay:** argmax/argmin signed-zero tiebreak ([d363a81](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/d363a8193817740401256c92adeae819fd7fee97))
* **overlay:** Dict literal constructor (closes all 18 Dict gaps) ([1f33cc6](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/1f33cc6657ad9edc524c989b5aea979f30bc45ce))
* **overlay:** exact fmod for rem/mod(Float64) + Float32 exp/exp2/exp10 redirect ([5d1f028](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/5d1f0282de7bd08c27df8243f67f178b73beeff1))
* **overlay:** first/last(Vector) bounds-check on empty ([ad48bb9](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/ad48bb94d67866784fa0aed51815e4515a61b002))
* **overlay:** float mod/rem fmod-faithful at Inf/zero divisors ([35018fa](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/35018fa0e3632c57a1654ebb642d3dd9e11f5660))
* **overlay:** maximum/minimum signed comparison + NaN (closes maximum∘sort class) ([4b5e29b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4b5e29bd4ac58f4ca422a231c55c643169337894))
* **overlay:** startswith/endswith accept SubString (AbstractString) operands ([a3cfc97](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/a3cfc975d4dcca49f120ebc3e766dffb336842f3))
* **overlay:** string(Int64) typemin (negation overflow) ([968bebe](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/968bebeeef577eab2bb9e7d9cff8c0a57cd94349))
* **overlay:** unique dedups NaN (NaN-aware equality) ([fff920a](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/fff920a9f079626d8625f7c13ac11a9d93a63787))
* **overlay:** unique(Vector{Float}) keeps ±0.0 distinctly (isequal semantics) ([70b4cd6](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/70b4cd6bd869cb70680e16476bf79a46c87e4250))

## [0.2.0] - 2026-06-05

### ⚠ BREAKING CHANGES

* **`strict=true` is now the default** for `compile`/`compile_multi`. Constructs that
  would compile to a *wrong value* (`objectid`/`jl_object_id`, non-zero `memset`) now
  raise `WasmCompileError` (with the offending construct + source location) instead of
  emitting a silently-incorrect stub. Sound traps on dead error-branches still compile.
  Pass `strict=false` to restore the previous permissive behavior.

### Features

* Source-attributed diagnostics: `WasmDiagnostic`, `WasmCompileError`, and a single
  `record_unsupported!` choke point for every "give up" site (`src/codegen/diagnostics.jl`).
* **`validate=true` default**: every compiled module is checked with `wasm-tools validate`
  and a reject raises `WasmValidationError` (was previously unvalidated / `@warn` only).
* Type-directed differential fuzzer under `test/fuzz/` (Supposition.jl): generates
  well-typed compositions, checks native-vs-wasm, auto-shrinks counterexamples, persists
  a `DirectoryDB` corpus, and documents each finding as a self-reproducing, auto-closing
  "gap" in `test/fuzz/failures/`. A bounded pass runs in CI.

### Bug Fixes

* `jl_object_id` no longer returns a constant `42` / array length (a silently-wrong
  identity hash); non-zero `memset` no longer silently mis-fills.

## [0.1.1](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.1.0...v0.1.1) (2026-04-20)


### Bug Fixes

* ship codegen + JSON 1.x migration fixes ([1f0ed5e](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/1f0ed5e35d7bf254a8e8ede9e057731813cdff8c))
