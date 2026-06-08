# Fuzzer findings — cross-cutting notes

Per-gap root-cause analysis now lives **inside each gap file** under its
`## Analysis` heading (`test/fuzz/failures/<id>.md`) — that section is **preserved
across fuzzer re-records** by `Ledger.record_gap!`, so a fix loop's notes are never
clobbered. See `failures/INDEX.md` for the live list. This file holds only
observations that don't map onto a single auto-generated gap.

## Remaining 16 gaps (the deep/feature long tail) — all root-caused & triaged for Part 2

Every tractable gap is fixed (see "Fixed" below). The 16 that remain each need real
codegen/feature work, not an overlay — full root-cause is in each gap file's
`## Analysis`. They collapse onto **six shared roots**, so the fix count is far smaller
than the gap count:

1. **Unicode `Char` tables (feature)** — `uppercase('é')` (`ff2542499cc2`),
   `isspace('é')` (`bc93362af34e`), `isdigit(uppercase('é'))` (`6bd3c602cf17`). Char
   case/category for codepoints ≥ 0x80 needs Unicode tables; ASCII works.
2. **Float→string / Ryu (feature)** — `string(::Float64)` (`19d59e9a61b3`); needs
   `Base.Ryu`. `string(::Int64)` works.
3. **map-kernel-dependency codegen** — a *compiled* function mis-executes when pulled
   in as a `map` kernel: `length(::String)` (`3b005c4957f7`), `atan`/`asin` with a
   constant arg (`5511171c8055`), and `Dict`-in-kernel (`a771b83dda7c`, `f3829eae0fbb`).
4. **SubString / `String(bytes)` codegen** — `codeunit(::SubString)` reads return 0 in
   nested builds, and freshly-built strings misbehave: strip unicode (`0beb5ec969a2`),
   `uppercase(::SubString)` (`05bc422e7ffb`). The reverted `length(::String)` overlay
   also lives here (see [3]).
5. **`Dict` construction edges** — duplicate-key Dict literals return garbage
   (`dbac068444b5`), and combine with SubString values (`627592b54cf2`) / strip
   defaults (`787f51057ef8`).
6. **scratch-local aliasing across operand boundaries** — `unique∘cumsum` then `lcm`
   (`a48cf6e47497`), `push!∘pushfirst!` + `Set` (`905344436a9f`); same class as the
   now-fixed `maximum(sort(...))` cluster. Fix = local reuse across operands.

Plus one isolated **constant-folding-parity** case: `0x01 << <Int64-typemin literal>`
(`31d4d64b9325`) — native folds it to `0.0`; WasmTarget evaluates the shift. The common
runtime narrow-shift bug it resembles is **fixed** (see below).

## Fixed (verified-closed via the loop)

- **`reduce`/`foldl`(Vector) with `min`/`max`** — `reduce(op, v)`/`foldl(op, v)`
  lowered through native `mapreduce`/`mapfoldl`, whose CFG keeps a `mapreduce_impl`
  block (the >1024-element branch) that emits invalid wasm. The module failed to
  validate **even for tiny vectors that never reach that branch**, so every
  reduce/foldl trapped (lax mode returned the MAX for a `min` reduction —
  `reduce(min,[5,3,8,1])` → 8). Fixed with `Base.reduce(op::F,::Vector)` /
  `Base.foldl` left-fold overlays (exact for the generated +/*/min/max). `op::F`
  forces specialization so the empty-collection identity folds to a constant
  (avoids a `dynamic invoke reduce_empty(…)::Union{}` that won't compile). Closed
  `742d636e6708`, `f1ba8bacdda5`; guarded by `@testset "reduce/foldl(min/max)"`.
- **`rem`/`mod`(Float64) precision** — `x - trunc(x/y)*y` rounds for large quotients;
  replaced with Sterbenz-exact scaled subtraction (bit-exact vs native fmod).
- **Float32 `exp`/`exp2`/`exp10`** — Float32 kernel emitted invalid wasm; redirect
  through the correct Float64 kernel (≤1 ULP).
- **Narrow-width integer `<<` (UInt8/UInt16)** — `0x01 << x` (a UInt8 shift) ran in an
  i32 register without truncating to the operand's width, so e.g. `0x01 << 8` gave 256
  instead of 0. Fixed in `_emit_shift_guarded!`/`_julia_int_width` (calls.jl): the
  over-shift threshold now uses the Julia type width and the `shl` result is masked to
  that width; the i64→i32 shift-amount wrap now saturates so a huge amount can't wrap
  to a no-op. Closed `39f963bc044a`. (The folded literal-typemin case `31d4d64b9325`
  is a separate constant-folding-parity edge — see above.)
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
