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
2. **Float→string / Ryu** — `string(::Float64)` (`19d59e9a61b3`) — NOW WORKS
   (2026-06-13 campaign re-check: `string(0.0/1.5/12345.678/-0.5/0.1)` all bit-exact
   vs native, standalone AND with bridge accessors in-module). The old "writeshortest
   unbalanced control frames in module-context" defect is gone. `19d59e9a61b3` itself is
   marked fixed; leaving this list entry only as a historical pointer.
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

- **structref-vs-concrete-ref type precision on `<: Number` structs (Pluto campaign,
  2026-06-13)** — `Complex`, `Rational`, `RGB{N0f8}`/`N0f8` are `<: Number`, so
  `is_struct_type` returns false and `get_concrete_wasm_type` types them as the abstract
  `structref` wherever they appear as a function PARAM or bridge-ctor arg — while the
  struct registry / field types use the concrete `(ref null $T)`. Two emission sites then
  mismatched: (a) `struct.get $T` against a `structref` param (Base `show(::Complex)`
  reads `z.re`/`z.im` — `func $show` param declared `structref`); (b) `struct.new $Outer`
  with a `structref` field value (PI Bridge ctors `_mk_…RGB…N0f8`, fractals Complex
  labels). Fixed with abstract→concrete `ref.cast null $T`: extended
  `emit_ref_cast_if_structref!` (context.jl) to the `Core.Argument`/param case, and added
  the matching ConcreteRef branch on the struct.new field path (statements.jl). The cast
  is a no-op when the value is already `$T` and traps otherwise (sound). Verified:
  `Bridge._make_ctor(RGB{N0f8})` + Base-only `Complex{Rational{Int64}}` ctor & field read
  now validate; closes the **RGB{N0f8} struct.new** gap (FINDINGS Class 2) and the
  type-precision half of **`cfd419793b0d`** (Complex display — its remaining show-machinery
  dead-value bug stays open). Guarded by `@testset "Numeric-struct field struct.new/
  struct.get (WASMTARGET-FUZZ)"`. Also removed a stray `DEBUG_STRUCT_NEW_2EXTERN` stdout
  `println` left in `compile_new`.
- **`sinh`/`cosh`/`tanh`(Float64) hyperbolic** — were value-stubs (no native
  codegen): `sinh(x)` emitted nothing on the stack, so `hypot(Inf, sinh(x))`
  failed wasm validation ("expected f64 but nothing on stack"). Implemented via
  the working `exp`: `cosh = (eᵃ+e⁻ᵃ)/2` (exact); `sinh` uses a Taylor branch for
  |x|<0.35 (the `eˣ-e⁻ˣ` form loses precision to cancellation near 0); both use an
  overflow-safe `eᵃ/2 = exp(a-ln2)` for |x|>20 (matches native finite `sinh(710)`
  where the naive form overflows to Inf); `tanh = sinh/cosh` with |x|>20 ⇒ ±1.
  Verified 42/42 vs native across the sample range incl. ±0/±Inf/NaN and the
  danger band [1e-12,1e-7]. Float32 redirects through Float64. Closed
  `0ef240ffe2b5`; guarded by `@testset "Hyperbolic sinh/cosh/tanh"`. (The
  generator's `expm1`/`log1p`/`sinpi`/… are the same value-stub class — next batch.)
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

## P4-stdlib: 1.13 wrapper-shape generator limitation (open, overlay-mitigated)

`Statistics.median(v::Vector{Float64})` on Julia 1.13: the WRAPPER
specialization inlines `copyto!`-machinery whose IR has a catchable
boundscheck throw arm (`invoke throw_boundserror; unreachable`)
immediately before an intra-range jump target, inside a function that
routes to the stackifier (conditionals > 2). The compiled module
validates but the runtime path dead-codes a later GotoIfNot condition
to `i32.const 0; unreachable` (V8 trap at the condition). The literal
definition `median!(copy(v))` — semantically identical — compiles
correctly; `WasmTargetStatisticsExt` reroutes the wrappers via
1.13-gated overlays.

Status: mitigated, root cause NOT fixed. The conditionals-path range
walk got a resume-at-jump-target fix (compile_range, P4-stdlib), but
this shape compiles via the stackifier whose per-block resets did not
prevent it — the dead-coding site is still unidentified (the flag
leaks somewhere between block statement compilation and terminator
condition emission). Forensics: WT_TRACE_DEADVAL=1 shows ~121
dead-value emissions; WT_TRACE_STUBARGS / WT_TRAP_STACK exist. A
depth-5+ fuzz sweep over boundscheck-arm + jump-target compositions is
the likely organic reproducer source; until then this note is the
tracking entry.

## PlutoIslands featured-corpus → WT work-list (2026-06-13)

Source: the 30 non-shipping bond groups of the PlutoIslands featured corpus
(35/65 ship after the PI bind fixes). Triage of every WT-side degradation
reason in `PlutoIslands/tools/ISLAND_SURVEY.md`. The blockers split into four
classes — **only Classes 1–2 are conventional codegen/fuzzer work**; Class 3 is
the larger bucket and is *not* fuzzer-tractable.

### Class 1 — genuine WT codegen bugs
- **Canvas-render: a MULTI-BUG CHAIN (2026-06-14 campaign).** The figure-render
  path (WasmMakie `render!` compiled via `compile_module` + canvas2d imports —
  turtles ×4, conv1d, conv2d ×4, newton figures, Titration) is gated by a CHAIN
  of codegen bugs, fixed one at a time via WasmMakie's `compile_with_canvas`
  harness + a focused W-002 differential (host RecordingCtx stream vs wasm
  command stream in node):
  1. **Int128/UInt128 struct FIELD registration — FIXED.** `_register_struct_type_impl!`
     lacked the `Int128|UInt128 → int128 struct ref` branch that `register_tuple_type!`
     has, so a render struct with a 128-bit field errored "Primitive type too large
     for Wasm field: Int128 (16 bytes)". Added the branch (structs.jl). NOTE this
     is a PRE-EXISTING main regression — `git`-confirmed the identical failure at
     main 1531b26, and the old "i64/f64 mismatch" symptom is gone/superseded; the
     baseline 38/65 survey was on an OLDER WT where canvas still compiled.
     Int128 *arithmetic on a field value* is a SEPARATE op gap (Int128 `÷`/`%`
     trap/mis-validate) — not needed for canvas, which only stores the field.
  2. **`print_to_string_1` f64/anyref — OPEN (next).** V8 rejects the figure at
     instantiate: `print_to_string_1: local.set[0] expected f64, found struct.get
     of anyref`. The axis-tick number-formatting path reads a Float64 from a struct
     field typed `anyref` (boxed) without unboxing — a module-context-sensitive
     type-precision/unbox bug (string(::Float64) works standalone; same print/
     IOBuffer machinery area as the median/Printf notes). wasm-tools accepts it;
     only V8 rejects, so WT's validate misses it. NEEDS a minimal module-context
     repro before fixing.
  Canvas won't ship until the rest of this chain clears; bug 1 of N done.
- **`string(::Complex{Float64})`** — gap **`cfd419793b0d`**, PARTIALLY progressed
  (2026-06-13 campaign). Reframed: `string(::Float64)`/Ryu now works standalone
  AND in module-context (the `19d59e9a61b3` unbalanced-control-frames defect is
  gone — verified), so this is NOT downstream of Ryu. It hid TWO bugs: (1) the
  structref-vs-concrete type-precision bug — **FIXED** (see Fixed section); (2) a
  show-machinery dead-value defect in `nonnothing_nonmissing_typeinfo` (`block`
  stubbed to `unreachable` then `ref.is_null` on an empty stack) — **STILL OPEN**,
  same class as median/Printf `format`. Gap stays open on (2). (Complex
  *arithmetic*/iteration compiles + runs bit-exact — only DISPLAY is gated.)
- **`compile_multi` array-vs-func type-index collision** — `func N failed to
  validate: expected array type at index 6, found (func (param (ref null (id 6))
  i32 i32) (result (ref extern)))`. When an assembled module contains BOTH an
  array-constant type AND a bridge/tree-walk accessor func type (`(result (ref
  extern))`), the type-table index management collides. Hit by Collatz (baseline)
  and by conv1d the moment PlutoIslands' partial-eval baked a *vector* constant
  (so PI now gates `_bakeable_const` to scalars/strings/tuples and re-allows
  vectors only after this is fixed). Not reproduced by a 3-entry `compile_multi`
  with a vector-indexing fn + string accessors — the trigger needs the specific
  bridge arg-descriptor / tree-walk accessor arrangement; minimization TODO from
  the conv1d module (func 8, offset 0x696).

### Class 2 — color-type codegen (needs ColorTypes/FixedPointNumbers in a fuzz env)
- **`RGB{N0f8}` `struct.new` mismatch** — **FIXED (2026-06-13 campaign).**
  `struct.new[1] expected type (ref null 30), found local.get of type structref`
  for `_mk_ColorTypes_RGB_FixedPointNumbers_N0f8_`. Root: `N0f8`/`RGB` are
  `<: Number` STRUCTS, so `is_struct_type` returns false and
  `get_concrete_wasm_type` types the bridge-ctor params `structref` while the
  struct field is the concrete N0f8 ref. Fixed with the abstract→concrete
  `ref.cast` on the struct.new field path (statements.jl) — the same fix that
  closed the Complex-param half. Reproduced+verified via
  `Bridge._make_ctor(RGB{N0f8})` and the Base-only `Complex{Rational{Int64}}`
  ctor; guarded by `@testset "Numeric-struct field struct.new/struct.get"`.
  Still distinct: `a9bf645b1003` (Matrix{NTuple{4,Float64}} pixel access).

### Class 3 — library-internals coverage gaps (NOT fuzzer-tractable)
Heavy library code inlined into the recompute closure, using reflection/identity
with no WasmGC lowering. WT already reports these honestly ("file this construct
as a coverage gap").
- **`objectid` / `jl_object_id`** — SymbolicUtils hashconsing (newton ×11),
  ImageTransformations (dither), Collatz Dict-with-custom-keys. ~3 notebooks.
- **cyclic `Method` constant** — `cannot compile Method: cyclic struct constant
  (object graph references itself)`. Figure renders capturing a `Method` object
  as a compile-time constant. Collatz ×9, Titration ×4, images.
- **`string(::Markdown.MD)` / show machinery** — Basic math's `stacktrace+object`
  cell rendering markdown.
- **`UInt128` field too large** — images. Bare `UInt128` arith AND a
  `UInt128` struct field both compile standalone, so the trigger is a specific
  deep library struct (unminimized).

**KEY STRATEGIC INSIGHT:** Class 3 is ~8–10 groups and is mostly NOT WT-fixable
via the fuzzer. Two sub-cases:
- **Bond-INDEPENDENT producers** (symbolic diff computed once, an image loaded,
  a constant table built): PI currently inlines this code into the recompute as
  CODE, dragging objectid/Method/show into the wasm — but the VALUE is identical
  across all bond settings. The PI lever is **export-time partial evaluation**:
  evaluate bond-independent upstream once and bake the resulting value as a
  constant (same spirit as the finite-transform baking), so the producer code is
  never compiled. Unblocks the subset where the heavy library is upstream of,
  not inside, the bond→body path.
- **Bond-DEPENDENT use** (the body genuinely calls into the library per bond
  value — e.g. `imresize` keyed by a slider): a true WT coverage gap; needs
  `objectid`/`Method` stub support or is fundamentally non-compilable.
(Both filed as PlutoIslands work-items; the partial-eval one is high-value.)

### Class 4 — already-tracked / not WT
`string(::Float64)` Ryu (`19d59e9a61b3`), Matrix{NTuple} pixel access
(`a9bf645b1003`), svg/table output mimes (PI mime support, not WT),
bond-defines-bond (PI feature).

### Generator-coverage suggestions (organic discovery)
- `Complex{Float64}` arithmetic + `string(::Complex)` (iteration works; display
  is the gap — `cfd419793b0d`).
- ColorTypes `RGB` / FixedPoint `N0f8` construction (needs a color sub-generator
  + deps).

## P4-stdlib: Printf probe results (stdlib #4 scouting)

1.12 out-of-box via bridge probes: **float formats PASS** (`%.3f`, `%e`
— riding the Ryu machinery) — the hard part of Printf already works.
Integer/string formats (`%d`, `%08x`, `%s`, padded `%6d`) trap in
`format` (wasm-function ~0xbc7): the byte shape is a phi-edge store
sequence where the edge VALUE compiled to bare `unreachable` ×2 then
`local.set` — a merge after a flattened throw arm (Union{}-rettype
catchable throws at invoke.jl ~2975/4641 set the dead flag; the arm's
phi-edge stores then compile dead values on what is at runtime a LIVE
path). A dead-context guard in emit_phi_local_set! did NOT change the
emitted bytes (reverted) — the emitting walker is elsewhere; next dig
should attribute via a stacktrace instrument inside emit_phi_local_set!
(mirror the WT_TRACE_CONDSTUB recipe that cracked the type-intersection
fold). Printf integration is otherwise the established playbook once
this one shape is fixed.

## P5-trim: differential matrix (discovery=:trim vs :legacy), 2026-06-12

| surface | 1.13 :trim | 1.12 :trim | legacy baseline |
|---|---|---|---|
| Statistics mean/std/quantile | PASS (bit-exact) | PASS | PASS (whitelist-cured) |
| Statistics median | validation err (print machinery) | validation err | PASS |
| Dates date-diff/parse | PASS | validation err (version-specific IR) | PASS |
| Random rand-i64 (seeded) | validation err (func 10) | compiles; exec needs "wasm:js-string" import (harness gap) | 1.12 PASS / 1.13 pair-locals |

Headlines: quantile passes under :trim with ZERO whitelist (legacy
needed :sort! curation). The collection is MORE COMPLETE than legacy —
it pulls error-formatting/show paths the whitelist never compiled,
which makes the deferred IOBuffer/print campaign the main blocker for
full parity (median both versions). Secondary digs: 1.12 date-diff
validation, 1.13 rand func-10 validation, and the harness's
importObject lacking the js-string builtin module some collected code
emits. Infrastructure landed: per-collection cache partitions
(cache_token / cache_owner), entry-scoped strict mode
(TRIM_ENTRY_NAMES), width-matched foreigncall defaults, TRIM_IR_CACHE
serving the collection's consistent-world IR through get_typed_ir.

### P5-trim update (same day, post-fix)

The matrix above is superseded: (1) the 1.12 Dates failures were the
void-return wrapper bug (try/catch 2-block structure emitted
`block (result T)` for Nothing-return functions — fixed in 51d3476,
both Dates probes now PASS on 1.12 under :trim); (2) Random under
:trim on 1.12 is 6/6 PASS (i64/f64/bool/range/stream/randn) once the
fuzz bridges enable wasm:js-string builtins and stub the io imports —
those were harness gaps, not compiler bugs; (3) 1.13 Random under
:trim is the pair-locals family (ref.cast lands on the i32 index of a
[ref,idx] memoryrefnew pair inside hash_seed — a517b4c8372d), so :trim
does NOT sidestep it; (4) bounded discovery differential
(discovery_differential(), 40 fixed-seed bodies × Int64/Float64 ×
both versions): :trim agrees with :legacy everywhere, with median
excluded as the one documented residual (deep show/print machinery,
the IOBuffer campaign). Net: :trim is at parity-or-better with legacy
on everything except median, on both versions.
