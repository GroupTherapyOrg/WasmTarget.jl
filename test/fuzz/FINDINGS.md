# Fuzzer findings — cross-cutting notes

Per-gap root-cause analysis now lives **inside each gap file** under its
`## Analysis` heading (`test/fuzz/failures/<id>.md`) — that section is **preserved
across fuzzer re-records** by `Ledger.record_gap!`, so a fix loop's notes are never
clobbered. See `failures/INDEX.md` for the live list. This file holds only
observations that don't map onto a single auto-generated gap.

## Remaining 16 gaps (the deep/niche long tail)

**Deep codegen bugs (focused work each):**
- `maximum(sort(...))` composition (3) — scratch/stack-local aliasing: an iterating
  left reducer (`sum`/`prod`) followed by `maximum(sort(...))` makes maximum return the
  min. Individual ops correct; only the composition fails; swapping operands fixes it.
- Float32 `exp`/`exp2` (2) — `exp(0.0f0)` emits invalid wasm in the compiled Float32-exp
  dependency function (validation failure; `sin`/`log`/etc. Float32 are fine).
- `strip` unicode (1) — gated on `ncodeunits`-on-`String(bytes)` aliasing + boolean-
  condition-before-`while` miscompile (see below).

**Niche edge cases (low value):**
- signed-zero (2): `argmax([-0.0,0.0,0.0])`, `unique([-0.0,0.0])` — Julia's `isless`/
  `isequal` distinguish ±0.0; our `>`/`==` treat them equal. (NaN cases now fixed.)

**Traps to investigate (4):** `first(map(asin,…))`, `isempty(Set([str,str,…]))`,
`map(y->length(""),v)`, `startswith("",chomp(""))` — string/Set edge traps.

**Composition/misc (4):** `mod(x, minimum(v))`, `cumsum(...) | lcm`, `gcd(count(...),
maximum(...))` — mostly natural-sig compositions; likely overlap with the above roots.

## Fixed (verified-closed via the loop)

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
