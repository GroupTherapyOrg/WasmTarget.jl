# Changelog

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
