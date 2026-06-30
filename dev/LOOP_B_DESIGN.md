# Loop B — ONE uniform classId-tagged box (the foundational keystone)

> ## ★★★ PARITY GATE — NON-NEGOTIABLE, EVERY STEP (Dale, burned in 2026-06-29 after a drift he caught + HATED)
> Build to STRUCTURALLY MATCH dart2wasm (`/Users/daleblack/Documents/sdk` pkg/{wasm_builder,dart2wasm}) — verify by
> differential+`Pkg.test()` for SOUNDNESS. **Differential-green ≠ parity; sound ≠ dart-faithful.** NOT DONE until WT
> structurally equals dart. **NEVER "done"/"cleanup-only"/"low-value" for anything not at dart-parity** — e.g. the 4
> box families STILL coexisting here is a PARITY GAP (dart has ONE), NOT cleanup. Every future edit carries this gate.

Branch `wt-dart2wasm-parity`. Adopt dart2wasm's value-boxing; DELETE WT's ad-hoc shadow
(i31 family + 3 disjoint tag schemes + WASM-type-keyed classId collapse). This is the
representation that B′ (collection element boxing), F3-L2 (typed Box consumes it), and
Loop C (convert_type! box/unbox arms) all build on. Approach like F3: design → incremental
committed-green sub-loops. Gate = distinguishability matrix + differential (NOT byte-identity —
this DELETES brittle code, the bytes SHOULD change). Loop A's validator already gates B's soundness.

## ★ THE DART ORACLE (from dart2wasm `pkg/dart2wasm/lib/src/`, agent-verified with citations)

1. **No separate "box" struct — reuse the normal class struct.** Boxed primitives `_BoxedInt`/
   `_BoxedDouble`/`_BoxedBool` are REAL classes. Universal layout (`class_info.dart:365-401`):
   - **field 0 = classId** `i32` IMMUTABLE — on the synthetic Top struct everything subtypes
     (`class_info.dart:368-370`; `FieldIndex.classId = 0` at :27).
   - **field 1 = identityHash** `i32` MUTABLE — but ONLY on `Object` subtypes (`class_info.dart:376-379`).
   - field 2+ = type-params then declared fields.
2. **Boxed primitives sit BELOW Top, NOT below Object** (`class_info.dart:299-310`) → they carry
   **NO identityHash slot**; their **field 1 IS the payload** (`FieldIndex.boxValue = 1`, shares the
   index with identityHash; validated :84-86). So a primitive box = exactly `[i32 classId, <payload>]`.
   Payloads (`translator.dart:183-185`): bool→i32, int→i64, double→f64.
3. **Boxing sequence** (`translator.dart:854-862`, the canonical convertType "to RefType" arm):
   `i32.const info.classId` → `local.get value` → `struct.new info.struct`. Constant boxes identical
   (`constants.dart:485-507`).
4. **classId = per-TYPE DFS pre-order** (`ClassIdNumbering._number`, `class_info.dart:575-690`): rooted
   at the no-superclass class, dense contiguous `Range` per subtree (powers is-checks), concrete ids
   from `firstClassId=1` and abstract ids in a DISJOINT range above them, id 0 = Top. Keyed on the
   **Dart TYPE, not the wasm representation** — distinct types sharing a wasm struct get distinct ids.
5. **Exactly 3 boxed primitives** (`translator.dart:202-206`): `{i32→bool, i64→int, f64→double}`. Each
   is its OWN distinct struct (not one shared), discriminated by classId. Boxing decision is pure wasm
   subtyping: value→RefType ⇒ box; RefType→value ⇒ unbox; ref→ref ⇒ cast/null-check. No escape hatch.
6. **Discrimination = `struct.get classId` (field 0) + integer range check** — `i32.eq` for a singleton,
   `id-start; len; i32.lt_u` for a range, OR-ed via block+br_if (`types.dart:585-588`,
   `code_generator.dart:3847-3884`, dispatch :2113-2119). NOT a chain of ref.tests on distinct structs.
7. **Unboxing** (`translator.dart:863-870`): optional `ref.cast` to the box struct (when static type
   isn't already it) + `struct.get` field 1.
8. **i31ref: NOT USED ANYWHERE** — grep of the whole dart2wasm tree finds zero. EVERY boxed int,
   including small ones, is a heap struct. ⇒ strongest signal: DELETE WT's i31 small-int fast path.
9. **instantiateDummyValue** (`globals.dart:99-126`): numerics→`const 0`, nullable ref→`ref.null`,
   non-null ref→`global.get` of a lazily-built dummy (struct → recurse per field + struct.new).

## DECISIONS this locks in (the "decide the identityHash slot NOW" call)
- **Primitive box layout = `[i32 classId, <payload i64/f64/i32>]`. NO stored identityHash/objectid slot.**
  Julia `objectid(1::Int)` is value-derived → compute on demand, no slot needed (mirrors dart: boxed
  primitives are below Top, not Object). If a hash slot is ever needed for boxed *mutable* objects, it
  goes at field 1 on the Object-equivalent subtree ONLY — never on the primitive boxes.
- **classId keyed on the JULIA TYPE** (via WT's existing DFS allocator, reportedly types.jl:143) — NOT
  the wasm rep. This is the P1 fix: Bool/Int8/Int16/Int32/Char must each get a DISTINCT id (today they
  collapse to Int32's id because the box is keyed on the wasm type).
- **Discrimination = struct.get(field 0) + i32 compare/range.** Adopt dart's range-check lowering.
- **DELETE i31** entirely — every boxed value is a heap struct `[classId, payload]`.

## WT SHADOW — the current boxing reality (agent-mapped, file:line verified)
**4 structurally-distinct box families, each with a leading `i32` typeId, in DISJOINT registries —
all doing the same job (carry a dynamic value + discriminant through anyref):**
1. **i31 box** (types.jl:395-432). Helpers `emit_box_i31!`/`emit_unbox_i31_s!`/`emit_unbox_i31_u!`
   = **DEAD (zero callers)**; `should_use_i31(T)` (Bool/Int8/UInt8/Int16/UInt16) still gates 2 live sites.
   Live `ref_i31!` sites: stackified.jl:108/153 (SAFE, ≤16-bit gated) — but calls.jl:2851/2853/6145/6148
   + invoke.jl:2110/2113 box I64/I32 **UNCONDITIONALLY → SILENT TRUNCATION ≥2^30**, AND then `ref.cast`
   the i31 to a struct ref = **guaranteed trap** (rep mismatch). unions.jl already abandoned i31 for §2.
2. **numeric box** (types.jl:1111-1120 `get_numeric_box_type!`): `[typeId:i32 imm, value:T imm]`, **KEYED ON
   WASM TYPE** (`registry.numeric_boxes[wasm_type]`) → Bool/Int8/Int16/Int32/Char/UInt8/UInt16 **collapse
   to the I32 struct**. ~45 wrap sites. Consumers `ref.cast box; struct.get 1`.
3. **union tagged-value** (unions.jl:107-152 `register_union_type!`): `[typeId:i32, tag:i32 mut, value:anyref
   mut]`, **per-union sequential tags** (tag_map), typeId field **always written literal 0**. DOUBLE-BOXES
   numerics (union field-2 anyref ← inner §2 numeric box). wrap/unwrap = emit_wrap/unwrap_union_value.
4. **nothing box** (types.jl:1149) `[typeId:i32]` singleton. + **F3 `box_types`/`get_box_type!`
   (types.jl:1134-1143) = DORMANT/dead** (no live callers; F3-L2 will consume the CANONICAL box instead).

**4 id namespaces:** **A = DFS classId** (types.jl:143-247 `assign_type_ids!` → `type_ids`/`type_ranges`,
keyed on Julia type — **KEEP, this is the classId source**); **B = collapsed wasm-rep typeId**
(`emit_box_type_id!` types.jl:380-392, maps wasm→{Int32,Int64,Float32,Float64,Any}→DFS id — **the P1
bug, DELETE**); **C = per-union tags**; **D = literal-0 placeholders** (unions.jl:273/285/298).
**P1 keying bug lives in TWO places that must change together:** `get_numeric_box_type!` (struct keyed on
WasmValType) + `emit_box_type_id!` (tag keyed on WasmValType).

**Consumer side (already dart-shaped!):** `emit_typeof!` (types.jl:459-466) = `ref.cast $JlBase; struct.get
$JlBase 0` — i.e. read field-0 typeId. isa = emit_typeof! + i32.eq (concrete, calls.jl:~1360) or DFS range
check (abstract, :1497-1534). dynamic dispatch type-switch (calls.jl:1573-1716). USER STRUCTS already store
typeId at field 0. So WT ALREADY has dart's "field-0 i32 classId on everything + struct.get to discriminate"
— the box just needs to store the REAL classId (A) not the collapsed one (B), and the families need unifying.

## INCREMENTAL SUB-LOOPS (each committed-GREEN, non-breaking until its flip; gate = distinguishability
## matrix + differential, NOT byte-identity — this DELETES brittle code so bytes SHOULD change)
- **NOTE — do NOT delete F3's `box_types`/`get_box_type!`.** dart's value-box (immutable `[classId,value]`)
  and Julia's `Core.Box` (a MUTABLE captured-variable cell) are different concepts; F3's box needs a mutable
  field. `get_box_type!` is F3-L2's legitimate (dormant) infrastructure, NOT Loop B shadow. Leave it.
- **B1 — fix the ONE clean reachable silent-truncation (calls.jl:2851/2853) [SCOPED DOWN after reading all
  sites].** The het-tuple field → AnyRef path boxes I64/I32 via `ref_i31!` UNCONDITIONALLY (no width gate) →
  TRUNCATES ≥2^30. The F32/F64 branch immediately below (calls.jl:2855-2861) already uses the numeric box —
  route I64/I32 through the same numeric box (collapse all 4 numeric `fw` into one numeric-box branch). No
  consumer breaks (no `i31.get_*` exists in-tree; consumers unbox via `ref.cast box; struct.get 1`).
  **RED-TEST-FIRST (mandatory — verify the path is HIT, not fix-blind):** the lossy line only fires when
  `union_wasm === AnyRef` (calls.jl:~2812 — the getfield SSA result type's wasm rep is AnyRef, NOT a registered
  tagged-union ConcreteRef). Must construct a Julia fn whose runtime-indexed heterogeneous tuple field is an
  Int64 ≥ 2^40 AND whose inferred result maps to AnyRef; confirm native-vs-wasm MISMATCHES before the fix and
  MATCHES after. (`should_use_i31` = Bool/Int8/UInt8/Int16/UInt16 only, so Int64 never takes the "safe" path;
  Vector{Any}-of-Int64 already uses the numeric box, NOT this i31 path — so the test must be the het-tuple-AnyRef
  shape specifically.) Gate: that differential + full Pkg.test.
  **DEFERRED to later sub-loops (entangled consumers — do NOT touch in B1):**
  - calls.jl:6144-6151 + invoke.jl:2109-2116 (i31 then `ref_cast!` to a concrete struct = ALWAYS-TRAP + truncate)
    → B3 (box unification clarifies what "numeric → a non-union concrete ref" should mean; today it traps = loud).
  - stackified.jl:108/153 (the should_use_i31 "safe" Bool/Int8 paths) → B2/B4: Bool-vs-Int8 are BOTH i31ref =
    indistinguishable (P1-in-i31-form), AND the comment relies on `ref.eq` for `===` → converting needs the
    boxed-`===` consumer (classId+value compare, not ref.eq) handled together. Delete `should_use_i31` + the 3
    dead helpers there.
- **B2 — THE P1 FIX: store the REAL Julia-type classId (A) in the box, retire the collapse (B).** At every
  numeric-box wrap site write `get_type_id(actual_julia_type)` not `emit_box_type_id!(wasm_type)`; change the
  matching isa/unbox consumers together so Bool/Int8/Int16/Int32/Char become DISTINGUISHABLE. (The struct may
  still SHARE the `[i32,T]` shape per wasm rep — sharing the shape is fine, dart discriminates by the classId
  FIELD, not the struct type.) Verify the box subtypes `$JlBase` so emit_typeof!/struct.get field-0 work
  uniformly (may need a declared supertype). Gate: the boxed-DISTINGUISHABILITY MATRIX over
  {Bool,Int8,Int16,Int32,Char,Int64,Float64} as an explicit fixture (isa/===/typeof each distinct).
- **B3 — UNIFY into one canonical classId box.** Collapse numeric_boxes + nothing_box (+ the union's inner
  numeric double-box) into ONE `get_boxed_value_type!`, all storing real classId at field 0, all subtyping
  $JlBase. Delete `emit_box_type_id!` (B) + the literal-0 placeholders (D, unions.jl:273/285/298) — the union
  tagged-struct keeps field 0 = real classId. Retire double-boxing. Gate: heterogeneous-Union/Vector{Any}/
  boxed-===/objectid set + differential + full Pkg.test.
- **B4 — i31 removal complete + lock.** Replace the last (safe) i31 sites stackified.jl:108/153 with the
  canonical box (dart uses NO i31), delete `should_use_i31` + `ref_i31!`/`i31.get` if fully unused. Restore/
  extend the distinguishability + boxed-===/objectid tests as a CI-wired shard. Full adversarial gate. Mark B done.

## ★ B2 INVESTIGATION FINDINGS (2026-06-29, probe-driven — RE-SEQUENCES Loop B)
**The P1 collapse IS observable + reachable**, but NOT where expected, and its fix is ENTANGLED with the
value-channel (Loop C). Probe data (boxed i32-repped types discriminated by isa at runtime):
- **Scalar `v::Any = literal; v isa T` — ALL CORRECT.** Inference keeps the static type; no box classId is
  consulted, so the collapse is masked. (So B2 has NO observable scalar red test — like Int128-div, sound there.)
- **Heterogeneous tuple, runtime index — P1 REPRODUCED:** `(true, Int8(7), Int32(9))[i] isa {Bool,Int8,Int32}`
  → Int8 and Int32 are BOTH misclassified as Bool (all return the first branch). Different-WIDTH types
  (Int32/Int64/Float64) already work (distinct box structs).
- **Vector{Any} — MORE broken:** every isa falls through to 0 (no type matches at all) — deeper, this is B′.
- **DECISIVE: storing the REAL classId in the box (at the het-tuple producer site) had ZERO effect on the
  consumer.** ⇒ the consumer does NOT read the box's field-0 classId — the het-tuple value is UNBOXED to a raw
  i32 BEFORE `isa` runs (isa then defaults to the first branch). Root structural facts: `get_numeric_box_type!`
  creates the box with NO `$JlBase` supertype (types.jl:1116, `add_struct_type!` no super), so `emit_typeof!`'s
  `ref.cast $JlBase; struct.get 0` can't uniformly read it; AND the value doesn't STAY boxed to the consumer.
- **STRUCTURAL HALF IS ALREADY DONE.** `set_struct_supertypes!` (types.jl:614) sets EVERY StructType with
  `supertype_idx===nothing` (incl. the numeric box) to subtype `$JlBase` — only the JlType hierarchy
  (jl_type_idx/jl_typename_idx) is excluded. So the box DOES subtype `$JlBase` and `emit_typeof!` CAN read its
  field-0 classId. ⇒ the reason storing the real classId had zero effect is **purely the CHANNEL: the value is
  eagerly UNBOXED to a raw i32 before `isa`, so the box is never consulted.**
- **CONCLUSION / RE-SEQUENCE (with Dale's "fundamental-first / combine-loops" steer 2026-06-29):** the fundamental
  blocker is NOT Loop B's box-rep (box exists, subtypes `$JlBase`, has the classId field — B1 fixed truncation) —
  it is **the typed VALUE CHANNEL (Loop C core): WT eagerly unboxes dynamic/Union values, dropping the
  discriminant before the consumer.** dart2wasm NEVER does this — a dynamic value stays a boxed ref (subtyping
  Top) until `convertType` coerces it at a boundary; a type-test reads classId off the still-boxed ref. So **the
  remaining Loop B distinguishability work COMBINES with Loop C's channel-core** — they are one fix: *keep dynamic
  values boxed-with-real-classId until a genuine convertType boundary; isa/typeof read the classId off the box.*
  Storing the real classId (the reverted producer edit) is a trivial sub-part that becomes value-verifiable ONLY
  once the value stays boxed. **NEXT (the minimal value-verifiable channel increment): trace WHERE the het-tuple
  `t[i]` union value is unboxed before `isa` (_compile_call_isa / the getfield-result SSA store), stop the eager
  unbox so the value reaches isa as the boxed ref, store the real classId at the producer, and let `emit_typeof!`
  discriminate. Re-probe `htup_disc` (Int8→2, Int32→3, not all→1) for the green.** This is a down-payment on
  Loop C, pulled in BECAUSE it's the fundamental that unlocks B2/B′ — not a detour.

## ★★ PRECISE ROOT (traced 2026-06-29) — the eager-unbox is at SSA-LOCAL TYPING
`v = t[i]` with `v::Union{Bool,Int8,Int32}` is stored in an SSA local **typed I32** — a multi-member Union is
collapsed to a RAW NUMERIC local, unboxing the value + dropping its classId at allocation. Then
`_compile_call_isa` (calls.jl:1323-1352, the `isconcretetype(check_type)` arm) reads `isa2_val_wasm` from
`ctx.locals[…]` = I32 and hits the **"numeric value on stack → isa is always TRUE; drop + push 1"** shortcut
(calls.jl:~1352) → every `v isa T` returns true → all match the first branch (`htup_disc` → act 1,1,1). The
shortcut is correct ONLY for a SINGLE concrete static type; it's WRONG for a Union repped as a collapsed numeric.
**THE FUNDAMENTAL FIX (channel-core, the next coding task):** a multi-type-Union SSA value must get a BOXED
local (AnyRef carrying classId via the numeric box / canonical box), NOT a collapsed numeric local — so
`isa2_val_wasm === AnyRef`, isa takes the ref path (ref.test/typeId on the box, calls.jl:~1370+), and reads the
real classId (then the reverted producer "store real classId at the het-tuple box site" becomes value-verifiable).
**WIDE BLAST RADIUS** — many Union values are currently numeric locals that "work" only because the shortcut +
single-possible-type masks it; changing Union SSA-local typing to AnyRef must be done red-test-first (htup_disc),
mechanically, full-suite-gated. Find the SSA-local type assignment for Union getfield results (the chokepoint that
picks I32 over AnyRef) — likely `julia_to_wasm_type_concrete`/`get_concrete_wasm_type` collapsing the Union, +
the het-tuple getfield result store. Re-probe `htup_disc` (Int8→2, Int32→3) for green. This is a Loop C
down-payment pulled forward BECAUSE it's the fundamental that unlocks B2 distinguishability + B′ collections.

## ★★★ THE SINGLE-SOURCE FUNNEL (Dale's call 2026-06-29: "use robust single-source commands, not ad-hoc per-site")
The wasm_builder lesson applied. The probe VALIDATED the mechanism (stay-boxed + real classId + read-classId →
`htup_disc` green) but the impl was scattered (1 of ~41 producer sites hand-edited + 2 inlined isa copies) — REVERTED.
Rebuild as ONE funnel + ONE discriminator, dart2wasm `convertType`-faithful:

- **ONE producer = `convert_type!` gains the box/unbox arms** (values.jl:383; today it explicitly SKIPS them). Add
  an optional `from_julia::Union{Type,Nothing}=nothing` so the box stores the REAL classId:
  - numeric `from` → ref `to`  ⇒ **box**: `emit_classid_box!(b, ctx, from_wasm, from_julia)` then upcast the box ref
    to `to` (the box subtypes `$JlBase`, so it's anyref-compatible).
  - ref `from` → numeric `to`  ⇒ **unbox**: `ref.cast <numeric box>; struct.get 1`.
- **ONE producer helper `emit_classid_box!(b, ctx, wasm_type, julia_type)`**: `get_numeric_box_type!(wasm_type)`;
  store value in a scratch local; push classId = `julia_type===nothing ? emit_box_type_id!(wasm_type) [fallback] :
  emit_type_id!(julia_type) [REAL]`; reload; `struct.new`. ALL boxing routes here → retires the ~41 scattered
  `emit_box_type_id!`+`struct_new` sites + `emit_numeric_to_anyref!`/`_externref!`.
- **ONE consumer helper `emit_isa_classid!(b, ctx, box_idx, check_type)`**: `tee tmp; ref.test(box_idx); if;
  reload; ref.cast(box_idx); struct.get 0; i32.const(get_type_id(check_type)); i32.eq; else 0; end` (the safe
  guarded pattern already used for structs at calls.jl:1407-1430). ALL `isa`/`typeof`/`===` on a boxed numeric
  route here → retires the 2 inlined isa copies (calls.jl ExternRef + AnyRef paths) + same for typeof/===.
- **`needs_anyref_boxing` (single-source already)**: keep the extension (same-wasm-rep Union ⇒ box) — but land it
  TOGETHER with the funnel so consumers can distinguish (else suite breaks: more boxing, no discriminator).
- **BUILD ORDER (each committed-green):** (F-i) add the helpers + convert_type! box/unbox arms ADDITIVE/dormant
  (byte-identical, gate suite) → (F-ii) route the het-tuple producer + isa consumers through them + needs_anyref_boxing
  extension; red-test `htup_disc` green (correctness gate) → (F-iii) progressively route the other producer/consumer
  sites through the funnel + DELETE the scattered boxing (per batch: differential + suite) → (F-iv) the i31 family +
  emit_box_type_id! collapse + union double-box fall out as the routing completes. This IS Loop C's convertType funnel.

## identityHash/objectid DECISION (locked): primitive box = `[i32 classId, payload]`, NO hash slot —
objectid of a boxed primitive is value-derived (compute on demand). A hash slot, if ever needed for boxed
MUTABLE objects, goes at field 1 on the Object-equivalent subtree only, never on primitive boxes (mirrors dart).
