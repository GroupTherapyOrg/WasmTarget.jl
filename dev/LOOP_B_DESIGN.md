# Loop B — ONE uniform classId-tagged box (the foundational keystone)

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
- **B1 — REMOVE i31 boxing entirely (SOUNDNESS + adopt dart's no-i31).** (a) Fix the lossy/trapping paths
  calls.jl:2851/2853/6145/6148 + invoke.jl:2110/2113 (unconditional ref.i31 of I64/I32 → truncate ≥2^30 +
  cast-to-struct trap) → full-width numeric box (§2), as unions.jl already did. (b) Trace + convert the
  "safe" sites stackified.jl:108/153 to the box too (VERIFY each site's CONSUMER first — there is NO i31.get_*
  consumer in-tree, so confirm where each i31 value is read). (c) Delete the 3 dead helpers + `should_use_i31`
  once unused. Real silent-miscompile fix. Gate: differential on a heterogeneous tuple / Any[…] carrying a
  value ≥ 2^40 native-vs-wasm + full Pkg.test.
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

## identityHash/objectid DECISION (locked): primitive box = `[i32 classId, payload]`, NO hash slot —
objectid of a boxed primitive is value-derived (compute on demand). A hash slot, if ever needed for boxed
MUTABLE objects, goes at field 1 on the Object-equivalent subtree only, never on primitive boxes (mirrors dart).
