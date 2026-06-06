# Fuzzer findings — cross-cutting notes

Per-gap root-cause analysis now lives **inside each gap file** under its
`## Analysis` heading (`test/fuzz/failures/<id>.md`) — that section is **preserved
across fuzzer re-records** by `Ledger.record_gap!`, so a fix loop's notes are never
clobbered. See `failures/INDEX.md` for the live list. This file holds only
observations that don't map onto a single auto-generated gap.

## Remaining 4 gaps (the deep/feature long tail) — all root-caused & triaged for Part 2

Every tractable gap is fixed (see "Fixed" below). The 4 that remain each need real
codegen/feature work, not an overlay — full root-cause is in each gap file's
`## Analysis`. Note three of them (`0beb5ec969a2`, `3b005c4957f7`) share a single
root: the map-kernel-dependency + `String(bytes)` aliasing codegen bugs. Fix those
once and both string gaps close together.

- **`string(::Float64)` / Ryu** (`19d59e9a61b3`) — float→string is unimplemented
  (needs `Base.Ryu` shortest-round-trip digit generation). `string(::Int64)` works.
  *Feature work.*
- **`length(::String)` as a map kernel** (`3b005c4957f7`) — Base's char-count loop
  traps when pulled in as a map-kernel dependency (`map(y->length(s), v)`). A
  lead-byte-count overlay fixes map BUT miscompiles inside `lstrip`/`rstrip` (which
  call `length` as a byte count), breaking the green ASCII strip tests — so it was
  reverted. Needs the underlying map-kernel codegen bug fixed. *Deep codegen.*
- **`strip`/`lstrip`/`rstrip` unicode** (`0beb5ec969a2`) — last unicode-string
  holdout (startswith/endswith/reverse on strings are now all fixed). Gated on
  two underlying codegen bugs: `ncodeunits` on a `String(bytes)` result (aliasing), and
  a complex boolean-condition + `break` in a `while` (miscompile). *Deep codegen.*
- **`unique∘cumsum` then `lcm`** (`a48cf6e47497`) — shared scratch-local aliasing in
  the local allocator: an `unique(cumsum(...))` left operand leaves a stale local that
  the right operand's `lcm` (binary-gcd) reads, so gcd(2,1)→2. Order-sensitive,
  operator-agnostic. Same *class* as the now-fixed `maximum(sort(...))` cluster. The
  real fix is in local reuse across operand boundaries. *Deep codegen.*

## Fixed (verified-closed via the loop)

- **`rem`/`mod`(Float64) precision** — `x - trunc(x/y)*y` rounds for large quotients;
  replaced with Sterbenz-exact scaled subtraction (bit-exact vs native fmod).
- **Float32 `exp`/`exp2`/`exp10`** — Float32 kernel emitted invalid wasm; redirect
  through the correct Float64 kernel (≤1 ULP).
- **`isless`(Float32) / `sort`(Vector{Float32})** — Base's Float32 `isless` emitted
  invalid wasm (`type mismatch: expected i64, found anyref`), so *any* Float32
  ordering failed to compile. Surfaced by the bounded CI fuzz (seed 0xCD) as
  `length(sort([0f0,0f0,0f0]))`; fixed with an `isless(::Float32,::Float32)` overlay
  mirroring the Float64 one. Regression-guarded by `@testset "sort/isless(Float32)"`
  in `runtests.jl` and by the CI fuzz seed itself.
- **`asin`(Float64)** — Base's 600-stmt asin traps as a *map-kernel dependency*;
  overlaid as `atan(x/√((1-x)(1+x)))` (atan works in map), ≤1 ULP.
- **`startswith`/`endswith`** — were String-only; generalized to `AbstractString` so
  SubString operands (e.g. `chomp(t)`) byte-compare in place (`String(::SubString)`
  would memmove-trap).
- **`unique`(Vector{Float})** — `==` deduped -0.0/0.0; Float-specialized overlays add a
  signbit check (isequal semantics) without breaking the String-safe generic path.
- **`maximum`/`minimum`(Vector)** — explicit signed loop + NaN poison; also dissolved
  the `maximum(sort(...))` scratch-aliasing composition cluster.
- **Dict construction/length** — ref/i64 confusion (closed 18 gap variants).
- **Integer shift `<<`/`>>` over-shift** — wasm masks the shift amount to `mod bitwidth`;
  Julia yields 0 (shl/lshr) or sign-fill (ashr) for shift ≥ bitwidth. Fixed with a
  width-aware guard (`_emit_shift_guarded!`, calls.jl). Closed 4 gaps.
- **`reverse(String)` unicode** — reversed bytes, splitting multi-byte codepoints.
  Now reverses by character. Closed 1 gap.
- Plus: `hypot`, `string(Int64)` (typemin), `first`/`last` bounds, `argmax`/`argmin`
  NaN+signed-zero, and the soundness apparatus (strict mode, value-stub refusal).

- **Integer shift `<<`/`>>` over-shift** — wasm masks the shift amount to `mod bitwidth`;
  Julia yields 0 (shl/lshr) or sign-fill (ashr) for shift ≥ bitwidth. Fixed with a
  width-aware guard (`_emit_shift_guarded!`, calls.jl). Closed 4 gaps.
- **`reverse(String)` unicode** — reversed bytes, splitting multi-byte codepoints.
  Now reverses by character. Closed 1 gap.

## Known deep gaps (entangled with underlying codegen bugs)

- **`strip`/`lstrip`/`rstrip` unicode** — overlays use `length(s)` (char count) to
  byte-index `codeunit` (drops trailing bytes of multibyte UTF-8). Switching to
  `ncodeunits` exposes TWO deeper codegen bugs the originals contort around:
  (1) **`ncodeunits` on a `String(bytes)` result** returns wrong values (aliasing),
  and (2) a **complex boolean condition + `break` in a `while`** loop miscompiles
  (whitespace-find loop stops trimming). A correct single-pass strip trips (2).
  Real fix needs those two codegen bugs fixed first — then strip becomes trivial.
- **Dict ops** — emit malformed wasm: `type mismatch: expected i64, found (ref $type)`
  — a ref/i64 confusion in Dict construction/length codegen (18 gap variants).

## Known deep gaps (need C-lib-call → WasmGC work)

- **`collect(Vector)` / memmove** — `collect([a,b,c])` lowers to a raw-pointer
  `memmove` foreigncall that doesn't map to WasmGC arrays → traps. Omitted from the
  generator (contrived for vectors); real `collect` coverage needs ranges/generators
  (Part 2) and a WasmGC `array.copy`-based memmove.

## Observations not yet captured as gaps

- **`Vector == Vector` traps.** `sort([0,x,x]) == sort([0,x,x])` traps in wasm where
  native returns `true`. Surfaced by a manual probe, not the fuzzer, because the
  generator has no `Vector{T} == Vector{T} → Bool` op yet. Add that op to
  `generators.jl` (`OPS`) and the loop will auto-discover + document it.

## Coverage gaps worth adding to the generator (the ongoing crank)

- `Vector == Vector`, `in`, `findfirst`, `searchsorted`
- `Dict`/`Set` construction + lookup (needs key/value sub-generators)
- `Int32`/`UInt*` numeric universes; `round/trunc(Int, ::Float64)` (trap-prone — good oracle targets)
- ranges with bounded literal sizes (`1:k`, `k:step:m`)
- string conversions once `int_to_string`/`float_to_string` are fixed (see those gaps)
