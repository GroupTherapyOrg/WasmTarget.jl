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

- **`i32.const` length operand for string/Symbol/array literals was UNSIGNED-LEB
  encoded (Pluto campaign, 2026-06-15)** — `compile_value` for `String`/`Symbol`
  (codegen/values.jl) and the large-array path (codegen/dispatch.jl) emitted the
  `array.new_data`/`array.new` LENGTH via `encode_leb128_unsigned`, but `i32.const`
  operands are **signed LEB128** (`s33`). A literal whose length lands in the band
  where unsigned-LEB ≠ signed-LEB — most commonly **[64,127]** (1-byte unsigned-LEB
  with bit-6 set: e.g. 90 → `0x5A`, signed-decodes to **−38**) — produced a NEGATIVE
  length → `array.new_data` with a huge unsigned count → `"requested new array is too
  large"` trap at RUNTIME. **Validation passed**, so it was invisible until executed;
  short literals (<64) coincidentally encoded identically, hiding it for a long time.
  Surfaced by PlutoIslands interactive-feedback cells (admonition HTML segments are
  ~89/102/217/230 bytes). Fix: `encode_leb128_signed(Int32(len))` at all three sites.
  Regression: `test/runtests.jl` "String literal length — i32.const signed-LEB"
  (runs in node; asserts wasm == native for a 90-char literal). NOTE: `array.new_fixed`
  *immediate* counts and type/segment/local indices are genuinely u32 — left unsigned.

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
- **heterogeneous-tuple runtime indexing + union-representation consistency (Pluto
  campaign, 2026-06-15)** — three coupled fixes that turn `Any[a, "x", a]` and
  `md"…$x…$y…"` interpolation from a hard `unreachable`/null-deref into working code
  (Basic-mathematics `:n` cell). (1) **Abstract `::Vector` struct FIELD** (e.g.
  `Markdown.Admonition.content::Vector`, a UnionAll) mapped to a raw array, but every
  Julia `Vector{T}` *value* is a vector-STRUCT (register_vector_type!) with no shared
  supertype — `struct.new` mismatched (`expected (ref $rawarray), found (ref
  $Vector{T}-struct)`). Now → `AnyRef` (structs.jl, `_register_struct_type_impl!`).
  (2) **Heterogeneous tuple + dynamic index**: `getfield(::Tuple{A,B,…}, i::Int)`
  (only homogeneous tuples were supported) now emits a runtime if-chain on `i` that
  reads field `i` and wraps it into `Union{fieldtypes…}` via `emit_wrap_union_value`,
  so the existing `isa`/π consumers work (calls.jl). `Base.getindex(Any, vals...)`
  loops exactly this. (3) **`get_concrete_wasm_type` ↔ `julia_to_wasm_type_concrete`
  union agreement**: the former returned `AnyRef` for a heterogeneous union while the
  latter (the SSA-local allocator) used the tagged-union STRUCT — so the final SSA
  store saw a false type mismatch, DROPped the value and substituted `ref.null` →
  null deref. `get_concrete_wasm_type`'s multi-variant-union branch now mirrors the
  local allocator (types.jl). Guarded by `@testset "Heterogeneous tuple runtime-index
  → tagged union"` + `@testset "Abstract ::Vector struct field"`. **Still open** above
  this: `string(::Markdown.MD)` / `Markdown.plain` recurse `plain(io, content[i])`
  over heterogeneous AST nodes (Paragraph/Bold/Admonition/…) — WT compiles the
  recursive call as a single static call with `ref.cast (ref null $MD)`, so it traps
  ("illegal cast") on a Paragraph. Full markdown rendering needs runtime dynamic
  dispatch over the AST node types (open-world) — a separate, larger gap; and a
  CONSTANT heterogeneous tuple with a runtime index still traps (the `obj_arg` is a
  `Core.Const`, a different compile path than the param-built tuple).
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
  2. **tagged-union FLOAT member — FIXED.** `print_to_string_1` failed
     `local.set expected f64, found struct.get of anyref`. Root: `emit_wrap_union_value`
     DROPPED a Float member and stored null (silent data loss for ANY `Union{Float,…}`),
     and `emit_unwrap_union_value` had no F64/F32 branch. Both now box/unbox the float via
     a `{typeId,value}` numeric box (unions.jl). Verified Union{Float64,String} +
     Union{Float32,Int64} round-trip; guarded by `@testset "Tagged-union Float member
     round-trip"`. (Mixed `Union{Int64,Float64}` is a SEPARATE remaining issue — int uses
     i31, float uses box, and the unwrapped-value local mistypes; was already broken.)
  3. **`nonnothing_nonmissing_typeinfo` dead-value — FIXED via overlay.** Runtime type
     subtraction (`nonmissingtype∘nonnothingtype`) can't lower → stubbed `unreachable` →
     block underflow (the dead-value/stackifier class, shared with median/Printf). Overlaid
     to `= Any` (exact for plain-IOBuffer float/Complex formatting; inference const-folds).
     **This also closes the codegen half of `cfd419793b0d` — string(::Complex) now compiles
     + validates.**
  4. **`TwicePrecision` arith — OPEN (next).** func `$TwicePrecision`:
     `i64.shr_s` with a `(ref null $type)` operand (ref-vs-i64 type confusion) — the
     high-precision range/tick arithmetic. `expected i64, found (ref null $type)`.
  Canvas won't ship until the rest of this chain clears; bugs 1–3 of N done, bug 4 open.
  **Canvas is a LONG chain** (each fix exposes the next deep Base-machinery bug:
  Int128 → union-float → typeinfo → TwicePrecision → …) — multi-fix effort.
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
- **Mutable-struct field mutation ACROSS RECURSION — OPEN (new, 2026-06-24).**
  A self-recursive fn that reads a `mutable struct` field into a local, mutates
  the field, recurses, then RESTORES the field from the local (`op = t.pos; …;
  t.pos = op`) traps **`unreachable`** at runtime when the struct also has a
  `push!`-ed `Vector` field; WITHOUT the vector field it instead fails wasm
  validation (`func N failed to validate: type mismatch`). The IDENTICAL struct
  mutation in a LINEAR loop (explicit work-stack) compiles + runs bit-exact — so
  the trigger is RECURSION-specific, not the struct/NTuple/Vector ops (each of
  which works standalone). Independent of NTuple-vs-scalar fields (both fail).
  **Minimal runnable repro committed: `test/fuzz/repro_recursion_mutstruct.jl`**
  (`run_recur` → `trap: unreachable`, `run_linear` control → pass; both native=255).
  Discovered reframing the PlutoIslands "turtles-art" L-system fractal
  (`lindenmayer`, binary recursion save/restoring turtle pos+heading); the notebook
  was shipped by rewriting the recursion ITERATIVELY (explicit stack), so this is
  noted for the loop, not blocking PI. Likely the dead-value/stackifier or a
  local-liveness-across-call-frames class; START from the committed repro.
- **(NOT a confirmed WT bug) turtles do-closure observation.** The same turtles
  fractal trapped when shipped as a bond-capturing `do t … end` CLOSURE passed to
  `turtle_drawing_fast(f::Function)` (allocating a `Vector{NTuple}` stack inside),
  but compiled fine as a plain `let` block. Could NOT be minimized to a WT repro:
  a closure that captures a param + allocates a `Vector{NTuple}` + mutates, passed
  to a higher-order fn, compiles + runs correctly standalone (verified), and the
  full turtle loop as a plain fn also compiles. So this is **harvester-path
  suspected, NOT a confirmed WT codegen gap** — flag for the PI harvester if it
  recurs; do not chase as a WT bug without a standalone repro.

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

## P4-stdlib: LinearAlgebra integration (stdlib #5, 2026-06-24) — SHIPPED (Approach A, no overlay)

Vector value-level surface, VERIFIED against native across random +
overflow/underflow-edge inputs under the differential oracle (`Bridge.tree_matches`
→ `_float_match`: bit-identical or ULP-tolerant rtol 1e-9 for floats, EXACT for
ints — the same oracle the fuzzer uses). Probes `/tmp/probe_la2.jl`,
`probe_la3.jl`. Catalogue entries added under `mod = :linalg`
(`test/fuzz/catalogue.jl`); runner gains `using LinearAlgebra: norm, normalize,
dot, cross`. NO ext / overlay — these all lower from LinearAlgebra's REAL
(generic, pure-Julia) implementations. (norm/normalize run the SAME generic
algorithm as native, so they agree bit-identically modulo at most FMA-contraction
1-ULP drift; integer `dot` agrees exactly.)

SHIPPED (Approach A, oracle-verified, regression-guarded by the catalogue):
- `norm(::Vector{Float64})→Float64`, `norm(::Vector{Float32})→Float32`,
  `norm(::Vector{Int64})→Float64` — dispatch to generic `norm(itr)`
  (generic.jl:708), NOT BLAS. The scaling path holds even on the
  `1e300`/`1e-300`/mixed-scale edges (158/158 inputs each).
- `normalize(::Vector{Float64/Float32})` — generic (158/158).
- `cross(::Vector{Float64/Float32}×2)` — generic; `throws=true`: length≠3
  raises `DimensionMismatch` and **wasm traps in parity** (verified 5/5 bad
  lengths trap).
- `dot(::Vector{Int64}×2)→Int64`, `dot(::Vector{Int32}×2)→Int32` — the
  GENERIC `dot(::AbstractArray,::AbstractArray)` path (generic.jl:983), exact
  integer arithmetic (150/150 + 140/140); `throws=true`: length-mismatch
  raises and wasm traps in parity (verified 4/4).

NEXT (overlay track, NOT in this commit) — `dot(::Vector{Float64/Float32}×2)`:
- Native dispatches to **BLAS** `dot` (matmul.jl:18, `where T<:BlasFloat`),
  a `ccall` WT cannot lower.
- **Strict-mode soundness hole (separate core finding):** under `strict=true`
  it currently compiles to a **SILENT `0.0`** (every input → `{"x":"0"}`,
  80/80) instead of loud-rejecting the BLAS `foreigncall`. This is exactly
  the silent-miscompile strict mode (#52) is meant to forbid — a `ccall`/
  `foreigncall` to BLAS should be a definite-unsupported loud reject. Flag
  for the soundness loop (LOOP.md); NOT specific to `dot` (any BLAS-typed
  LinearAlgebra entry hits it).
- **The overlay (Dale's GenericLinearAlgebra lever):** the differential oracle
  is tolerance-based (`oracle_policy.jl`: rtol 1e-9), so a pure-Julia reroute
  that differs from BLAS only by reassociation rounding PASSES for
  well-conditioned inputs. Reroute `dot(::Vector{<:BlasFloat})` to Base's OWN
  generic `dot(::AbstractArray,::AbstractArray)` (via `invoke`) in a new
  `ext/WasmTargetLinearAlgebraExt.jl`; GenericLinearAlgebra itself is only
  needed for the factorization surface below (Base has no generic fallback
  there). **Caveat — conditioning, not method:** generic vs BLAS differ on
  2213/5000 random pairs (worst rel ~2e-4) but only on ill-conditioned inputs
  with heavy cancellation; those few exceed rtol 1e-9 and are a per-op
  tolerance / generator-conditioning question (human-pinned oracle file), not
  a reason to skip the overlay. Downstream (WasmMakie/PI geometry) is
  well-conditioned. See memory `wt-genericlinearalgebra-overlay-lever`.

Matrix / factorization surface (`*`, `det`, `tr`, `svd`, `eigen`, `qr`, `lu`,
matrix `norm`/`opnorm`) — the GenericLinearAlgebra-overlay track proper, gated
on TWO prerequisites: (1) the bridge generators cover `Vector` but not 2-D
`Matrix` yet (needs `arg_descriptor`/`value_to_tree` 2-D support); (2) these
call LAPACK/BLAS directly with NO Base generic fallback, so they need
GenericLinearAlgebra.jl's pure-Julia impls overlaid (weakdep + ext), verified
under the tolerance oracle.

### Matrix surface progress (Inc 3–4, 2026-06-24) — SHIPPED

Prereq (1) cleared: `src/bridge.jl` now has return-side `mat` support (descriptor
+ rows/cols/get accessors + WALK_JS + `tree_matches`/`tree_decode`), mirroring the
arg side. The matrix surface is verified by `test/fuzz/linalg_diff.jl` (direct
differential sweeps; the generator does Vector, not Matrix), wired into the fuzz
pass via `fuzz_suite.jl`. Each op is wrapped in a NAMED function so it is a
CALLEE — overlays apply to callees, NOT to a bare op compiled as the bridge entry
(real cell functions always CALL these ops, so this matches downstream).

SHIPPED (oracle-verified vs native, all in `linalg_diff.jl`):
- Pure (Approach A, no overlay): `permutedims`/transpose, `triu`, `tril`, `kron`,
  `diagm`, `diag`, `tr`, `opnorm(M,1)`, `opnorm(M,Inf)`, `norm(M)` (Frobenius),
  predicates `issymmetric`/`ishermitian`/`isdiag`/`istriu`/`istril`; matrix `-`,
  scalar `*`, unary `-`.
- Core overlays (`interpreter.jl`, mirror the `copy(::Vector)` one): `copy(::Matrix)`,
  `copyto!(::Matrix,::Matrix)`, `+(::Matrix,::Matrix)`. **Why:** the 2-D `memmove`
  foreigncall + the VARARGS `+(A::Array,Bs::Array...)` broadcast instantiation
  silently produced a ZERO matrix (1-D copy/`-`/scalar-`*` already worked) — a
  wrong-value miscompile that blocked `triu`/`tril`/`copy`/`+`. Element-wise loops
  are bit-identical. (Another strict-mode silent-zero hole, like the `dot` BLAS
  ccall — same flag for LOOP.md.)
- Ext overlays (`WasmTargetLinearAlgebraExt`, BLAS reroute): matmul `*(::Matrix,::Matrix)`
  and matvec `*(::Matrix,::Vector)` → the textbook triple/double product (what
  `generic_matmatmul!` computes). `invoke`-to-generic does NOT work (generic `*`
  re-dispatches via `mul!` back to BLAS), so the kernel is written out; value-
  identical to BLAS modulo summation order (oracle rtol 1e-9), verified 40/40.

### Decomposition surface (Inc 5, 2026-06-24) — the codegen wall + the hand-rolled unlock

**KEY FINDING:** the LAPACK paths AND GenericLinearAlgebra's pure-Julia algorithms
BOTH hit WT codegen `WasmValidationError`s (or wrong values) — GLA is NOT the
unlock (verified: `GLA.eigvals`→validation error, `GLA.svdvals`→mismatch). The
library QR/Householder machinery is what WT can't compile. **BUT simple textbook
algorithms compile + match native under the tolerance oracle** (rtol 1e-9):
- hand-rolled back/forward substitution: OK 30/30
- hand-rolled cyclic Jacobi (symmetric eigvals): OK 30/30
- hand-rolled Cholesky factor: OK 30/30
So the decomposition surface is feasible via HAND-ROLLED overlays, Float64-only
(Float32 iterative algos differ from native by ~1e-7 > rtol → not oracle-verifiable).

SHIPPED (ext overlays, hand-rolled, verified in `linalg_diff.jl`):
- `det`/`logdet` — Base `generic_lufact!` (compiles) + det/logdet of it.
- `inv` / `\` (solve) — `generic_lufact!` + manual forward/back substitution on
  its packed factors & pivots. Float64. Verified 30/30 each.
- `svdvals` — ONE-SIDED Jacobi SVD (rotates columns of A directly; accurate,
  unlike AᵀA). Transpose when wide so m≥n. Float64. Verified 40/40 (tall/wide/sq).
- `eigvals`/`eigmax`/`eigmin` (Symmetric) — cyclic Jacobi. The kwarg-dispatch
  interception that blocked a positional overlay is SOLVED: write the overlay WITH
  the kwarg signature (`eigvals(A::Symmetric; sortby=nothing)`) and it intercepts.
  eigmax/eigmin use the `eigvals(A,k:k)` RANGE form → overlaid directly. Float64.
- `cond`/`rank`/`opnorm(A,2)` — FREE: they call `svdvals` as a callee, so the
  overlay applies (verified 30/30 each, no new code).

NEXT (codegen feasibility cleared; remaining work is object-build + types):
- factorization OBJECTS (`lu`/`qr`/`cholesky`/`eigen`/`svd`) — the VALUES ship;
  the objects + their factor matrices (sign/order-ambiguous vs LAPACK) verify via
  RECONSTRUCTION (A≈Q·R, A≈U·S·Vᵀ, A≈V·Λ·Vᵀ), a separate object-overlay task.
- `pinv`/`nullspace` — need the full SVD U/V (object task above).
- `cholesky`: factor computation compiles (mychol OK), but `cholesky(A)` returns
  a `Cholesky` OBJECT — overlay must build + return it so `.U`/`.L`/`\` work.
- `qr`: modified Gram-Schmidt (untried; simple loops, likely compiles).
- general (nonsymmetric) `eigen` + COMPLEX spectra: Jacobi is symmetric-only;
  needs real QR-iteration → likely the genuine out-of-scope boundary.

## LinearAlgebra — FULL-COVERAGE LEDGER (every name accounted for, 2026-06-24)

`names(LinearAlgebra)` = 106 functions + 41 types + 3 consts. Each is SUPPORTED
(verified in `test/fuzz/linalg_diff.jl` or the catalogue) or an EXPLICIT BOUNDARY.
The cardinal rule held throughout: **no silent wrong values shipped** — every
shipped overlay is oracle-verified; the boundary surface either loud-rejects
(WasmValidationError under strict mode) or is documented here.

✅ SUPPORTED + oracle-verified (~50 names), Float64 (+ Float32/Int where noted):
- vector: `norm` `normalize` `cross` `dot`(all elt types)
- arithmetic: `+` `-` `*`(matmul/matvec) scalar-`*` `copy` `copyto!`
- shape/extract: `transpose`/`adjoint`(eager) `permutedims` `triu` `tril` `kron`
  `diagm` `diag` `tr` `checksquare`
- norms: `opnorm`(1/2/∞) `norm`(Frobenius) `cond`
- factorization VALUES: `det` `logdet` `inv` `\`(solve) `svdvals` `eigvals`
  `eigmax` `eigmin` `rank`
- factorization OBJECTS `lu`/`cholesky`: `lu(A)\b`, `det(lu(A))`,
  `cholesky(A)\b`, `det(cholesky(A))` — lu→`generic_lufact!` (real LU object),
  cholesky→hand-rolled upper factor; downstream `\(::LU/::Cholesky, b)` overlaid.
- predicates: `issymmetric` `ishermitian` `isdiag` `istriu` `istril`
- structured-type OPS + dense CONVERSION: `Diagonal*vec/mat`, `Symmetric*vec`,
  `Upper-/LowerTriangular*vec`, and `Matrix(::Diagonal/::Symmetric/::Hermitian/
  ::Upper-/::LowerTriangular)` + `hermitianpart` (conversions overlay an explicit
  dense fill / hand-rolled structured matvec, bypassing the BLAS/copyto! gaps)

🔶 SUPPORTED with a DOCUMENTED soundness boundary:
- `inv`/`\`/`det`/`logdet`: sound for NONSINGULAR inputs (the math domain). On
  exactly-singular inputs, generic-LU (our path) vs LAPACK may diverge on throw
  behavior (rare, measure-zero for generic inputs; verified 14–17/20 trap-parity).
- ALL decompositions are **Float64-only**: Float32 iterative algorithms differ
  from native by ~1e-7 (Float32 eps) > oracle rtol 1e-9 → not oracle-verifiable.

⛔ BOUNDARY — NOT supported (loud-reject via validation error, OR needs work):
- factorization OBJECTS `qr`/`svd`/`eigen`/`schur`/`lq`/`hessenberg`/
  `bunchkaufman`/`ldlt`/`factorize` — store packed-LAPACK form (Householder
  reflectors / eigenvectors), hard to build as real objects + sign/order-ambiguous
  vs LAPACK. Their VALUES ship (svdvals/eigvals). (lu/cholesky DO ship — explicit
  factors; see supported.) `qr`/`eigen`/`svd` objects would need reconstruction
  verification — a future batch.
- in-place `mul!`/`ldiv!`/`rdiv!`/`lmul!`/`rmul!`/`axpy!`/`axpby!` (mutating;
  moderate); structured ops beyond matvec (Tridiagonal/Bidiagonal/SymTridiagonal);
  `kron!` — not yet covered (tractable follow-ups).
- `pinv` `nullspace` — need full SVD U/V (only `svdvals` ships). pinv via normal
  equations is UNSOUND for rank-deficient (not shipped).
- `sylvester` `lyap` — Bartels–Stewart needs `schur` (object). `lowrankupdate/
  downdate`, `givens` `rotate!` `reflect!`, in-place `mul!`/`ldiv!`/`rdiv!`/
  `lmul!`/`rmul!`/`axpy!`/`axpby!`, `condskeel` `isbanded` `diagind` `diagview`
  `copy_adjoint!`/`copy_transpose!`/`copytrito!` `fillstored!` — not yet covered.
- general (nonsymmetric) `eigen`/`eigvals` + COMPLEX spectra — Jacobi is
  symmetric-only; needs QR-iteration that hits the codegen wall. GENUINE boundary.
- `peakflops` (timing/threads), `BLAS`/`LAPACK` submodules (raw ccall wrappers) —
  genuinely non-wasm; out of scope by nature.

⚠️ CORE soundness items for LOOP.md (silent-miscompile holes found + fixed-by-overlay
in LA, but latent for any un-overlaid BLAS/LAPACK-typed op): BLAS `dot` ccall → 0;
2-D `memmove` → zero matrix; native `svdvals`/`inv` LAPACK → invalid-wasm or wrong
value. Strict mode should LOUD-REJECT every `ccall`/`foreigncall` to BLAS/LAPACK so
the un-overlaid boundary surface can never silent-miscompile.

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
