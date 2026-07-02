# WasmTarget → dart2wasm parity — REORIENTED loop sequence (2026-06-29 discovery swarm)

> ## ★★★ PARITY GATE — NON-NEGOTIABLE, EVERY STEP (Dale, burned in 2026-06-29 after a drift he caught + HATED)
> 1. **BEFORE building:** open dart2wasm (`/Users/daleblack/Documents/sdk` pkg/{wasm_builder,dart2wasm}), find the
>    analogous code, build to **STRUCTURALLY MATCH** it. Don't invent — mirror.
> 2. **AFTER building:** verify by differential native-vs-wasm + `Pkg.test()` — the **SOUNDNESS** gate.
> 3. **DIFFERENTIAL-GREEN ≠ PARITY. Sound ≠ dart-faithful.** A passing test = CORRECT, NOT that it matches dart's
>    structure. A step/loop is **NOT DONE until WT structurally equals dart2wasm.**
> 4. **NEVER write "done" / "cleanup-only" / "low-value" for anything whose dart-parity structure isn't reached.**
>    Structural unification toward dart's design IS the core mission, NOT cleanup.
> 5. **EVERY future loop edit/creation MUST carry this gate.** differential+Pkg.test = "is it SOUND?" · dart2wasm =
>    "is it PARITY?" · BOTH required; NEVER substitute one for the other.

Output of a 15-agent reorientation swarm (13 per-dimension WT-vs-dart2wasm audits + synthesis +
adversarial critique). Supersedes the old `Loop 0/A/B/C/D/E` order in `PARITY_LOOP.md`. The ETHOS
(`[[feedback-pure-dart2wasm-ethos]]`): every loop = ADOPT one dart principled design + DELETE the WT
ad-hoc shadow it replaces. Verified against the real Julia compiler (differential + Pkg.test), mechanistic.

## ★ NORTH-STAR / DEFINITION OF DONE (Dale): "WT's result type is a byproduct of emission" — same as dart2wasm.
dart2wasm: `node.accept1(this, expected) -> w.ValueType` — every visit RETURNS the type it left on the typed
stack; the type is never re-guessed. WT can make the SAME claim ⟺ ALL of:
  1. `compile_value` emits into the shared typed `InstrBuilder` and RETURNS the `WasmValType` it pushed
     (= `b.v.stack[end]`, which the typed validator already advances on every instruction) — not `Vector{UInt8}`.
  2. `infer_value_wasm_type` is DELETED (0 calls); the 267 re-guess sites + the `pushes=[infer…]` bridges are gone.
  3. The 4-way "MUST agree" resolver duplication (types.jl:1899 / context.jl:572 …) collapses to ONE resolver.
  4. Coercion flows through the ONE `convert_type!` funnel at the boundary (dart's `wrap`).
Precondition: the typed stack must be PRECISE + TRUSTED first — that's why **Loop A (wire `wasm_subtype` into the
validator) is the keystone FIRST loop**. When this holds, "compiled ⟹ the type is known exactly, for free" is true
in WT exactly as in dart. That sentence is the test for whether the whole type-channel work is actually finished.

## The one root cause + the lever
WT RE-GUESSES type info that dart2wasm carries for free. WT already has the dart-mirroring substrate —
a faithful `wasm_subtype` lattice (values.jl:253), a real `convert_type!` funnel (values.jl:349), a typed
operand-stack validator (validator.jl:42), a DFS classId allocator (types.jl:143) — all built but **wired
into ~nothing**. Each loop activates one dormant piece dart's way, then deletes the shadow it replaces.

## Hard numbers (critique-verified — old plan had these wrong)
`infer_value_wasm_type` = **267 calls** (not 198) · `emit_raw!` = **828 sites** (not 307) — partition by
`pushes=` before sizing C/D · `convert_type!` has **NO box/unbox arm** today (values.jl:349-398) → Loop C's
funnel work is NET-NEW + hard-blocks on Loop B · its numeric-widening (values.jl:387) is a SETTLE (dart
throws on numeric→numeric) → split into `coerce_numeric!`.

## ▶ LIVE STATUS + PARITY-ANCHORED FORWARD PLAN (2026-06-29, corrected after Dale caught the drift)
**HONEST PARITY: ~20-25% (≈1-2 of 12 dims). The differential oracle is GREEN broadly = SOUND, but NOT dart-parity.**
- ✅ **Loop A DONE** (5fd44ce, validator uses wasm_subtype). ✅ **Loop 0 partial** (P13 bf864a2 + F17 ad7b0fa; Int128-div
  + EH-tag deferred → EH-tag right before Loop D).
- 🟡 **Loop B = SOUND, NOT PARITY.** Committed + differential-green: B1·F-i·F-ii·F-iii-b1·B4a-e·boxed-===·cast-trap
  (distinguishability same-rep/diff-width/mixed-width/Char, boxed-=== silent-miscompile, mixed-width invalid-wasm,
  i31 FULLY removed). **BUT the box is NOT unified to dart's design:** WT still has **4 box families** (numeric_boxes
  {typeId,value} + union {typeId,tag,value} 3-field + nothing box + F3 box_types) where **dart has ONE** uniform
  {classId,value} subtyping the Top struct (`class_info.dart`). **Collapsing them = the real Loop-B PARITY work, NOT
  cleanup** (this is the drift Dale caught). Earlier "distinguishability is the channel" finding still true (the
  channel work is Loop C), but B is not parity-done until the box is ONE.

## ▶ THE PARITY-ANCHORED FORWARD SEQUENCE (what "done" requires = STRUCTURAL match to dart, per the PARITY GATE)
1. **Loop B parity finish — UNIFY THE BOX (start here).** dart `class_info.dart`: one box = `{classId:i32@0, value@1}`,
   classId = real per-type DFS id, discriminate by `struct.get classId` + range. Collapse WT's 4 families into ONE
   `get_boxed_value_type!` (all storing the real classId, all subtyping the Top struct); retire the union {typeId,tag,
   value} 3-field scheme (unions.jl) + `emit_box_type_id!` collapse + the disjoint registry dicts; route the ~41 inline
   sites + the union wrap/unwrap through the one box + `convert_type!`. CHECK class_info.dart/translator.dart at each step.
2. **Loop C — typed value channel (THE NORTH-STAR).** `compile_value` RETURNS its WasmValType (dart `node.accept1 ->
   ValueType`); DELETE `infer_value_wasm_type` (267 re-guesses) + the emit_raw! bridges + the 4-way resolver dup + the
   coercion ladders → the ONE `convert_type!` funnel. Fixes the #1 silent-wrong filtered-fold (`_InitialValue` sentinel).
3. **Loop D — strict + total loud-reject.** dart THROWS on type mismatch; WT's validator only RECORDS → wire
   has_errors→throw, delete the 2 escape hatches; typed emitters, delete RawBytes. Needs Loop 0's EH payload tag.
4. **Loop E [LARGEST DELTA, mostly untouched] — closures + dispatch + GC class-info.** dart ClosureRepresentation
   (`closures.dart`) + classId+offset dispatch table (`dispatch_table.dart`; WT still O(n) if-chain) + class-info GC model.
5. **Deferred but REQUIRED for 1:1:** strings i16 · EH catchable driver · Float16 · linear-memory · Int128 full div/rem.

**(superseded note kept for trace:)** the old "Loop B distinguishability is the channel" combine — true, and done as
F-ii/B4; the channel itself is Loop C (#2 above). Full Loop-B detail: `dev/LOOP_B_DESIGN.md`.

## THE SEQUENCE (dependency-ordered; revised per the LIVE STATUS above)
- **Loop 0 — free soundness banking** (small, independent, FIRST; de-risks A). Adopt: always-on cast verify,
  saturating-trunc struct, dedicated exception tag. Delete/add: ✅ref.cast `target⊄input` reject (validator.jl:701,
  P13); ✅typed TruncSat (statements.jl:3328, F17); emit_int128_div/rem (calls.jl:4395, F10 — DEFERRED); **EH tag with
  AnyRef PAYLOAD + value-carrying throw** (DEFERRED → do right before Loop D, which blocks on it). Gate: fuzzer + Pkg.test.
- **Loop A (FINISH) — wire `wasm_subtype` into the LIVE validator [KEYSTONE #1, THE FIRST ACTIONABLE LOOP].**
  The lattice exists but the validator is STILL PERMISSIVE: validator.jl:84/441/491/530 call
  `wasm_types_assignable` (:147), the struct (validator.jl:42) has no `mod`. Add `mod`, thread from InstrBuilder,
  replace the 4 calls with `wasm_subtype`, delete the permissive helper + `_is_ref_type` (B6), add the ref.cast
  reject. **GATE (critique §4 — byte-identity WON'T catch this):** compile_value builds the validator with no mod
  → the hot path silently runs the degraded `mod===nothing` relation (can't resolve ConcreteRef supertype chains).
  Assert mod-non-nothing on non-trivial paths OR fail loud + a differential test injecting a known-bad ConcreteRef
  subtype flow, asserting reject WITH mod threaded. Gates B/C/D soundness.
- **Loop B — ONE classId box for ALL dynamic/Union/Any [KEYSTONE #2, #1 functional gap].** Adopt dart `boxedClasses`
  `{classId:i32@0, value@1}`, classId = real Julia-type DFS id, discrimination = `struct_get classId`. ✅ B1 done
  (het-tuple i31 truncation → numeric box). identityHash DECISION LOCKED (no slot on primitives; box=[i32 classId,
  payload]). The box ALREADY subtypes `$JlBase`. **REMAINING = the distinguishability half, which COMBINES with the
  channel-core below (NOT a standalone box change).** Still to delete (during/after the channel-core): the i31
  family (types.jl:400-432 + calls.jl:6144 + stackified.jl:94-156, F31; B1 did the het-tuple site), `emit_box_type_id!`
  WASM-type keying (P1), the union {typeId,tag,value} 3-field + per-union tag (unions.jl), the disjoint registry
  dicts. Gate: the boxed-DISTINGUISHABILITY MATRIX {Bool,Int8,Int16,Int32,Char,Int64,Float64} + het-Union/Vector{Any}/
  boxed-===/objectid set.
- **★ CHANNEL-CORE (the fundamental, pulled forward — combines Loop B distinguishability + Loop C core).** WT collapses
  a multi-member-Union SSA value into a raw-numeric local (unboxing it, dropping classId at allocation) → `isa` mis-fires.
  FIX: give multi-type-Union SSA values a BOXED local (AnyRef carrying classId), NOT a collapsed numeric, so `isa`/`typeof`
  read classId off the box (dart-faithful: value stays boxed until convertType). WIDE BLAST RADIUS → red-test-first
  (`htup_disc`), mechanical, full-suite-gated. Find the SSA-local-type chokepoint (julia_to_wasm_type_concrete/
  get_concrete_wasm_type collapsing the Union) + the het-tuple getfield result store. THIS unlocks B2 + B′. Spec: `dev/LOOP_B_DESIGN.md`.
- **Loop B′ — collection element boxing** (rides on the channel-core). Vector{Any} / heterogeneous Tuple /
  Dict-value store classId-boxed elements through the SAME rep → closes the abstract-Dict ×10 (#1 fuzzer) cluster
  (probe showed Vector{Any} isa → 0). Needs no closures; after the channel-core, before C's broad sweep.
- **F3 L2 — typed `Box{contents}` cell** (L0/L1 done; AFTER Loop B — it consumes the canonical box, else its
  hard-gated adversarial set re-verifies twice). The smallest self-contained proof of the typed channel. spec dev/F3_LOOP.md.
- **Loop C — typed value channel + convertType funnel + flow/phi/Label dedup [KEYSTONE #3, biggest deletion].**
  NOTE: its CORE (don't unbox dynamic/Union values; keep them boxed-with-classId to the consumer) is PULLED FORWARD
  as the channel-core above, because it's the fundamental that unlocks B2/B′. Loop C proper = the full sweep:
  `compile_value_into!(b,val,ctx)::WasmValType` (= b.v.stack[end]); delete `infer_value_wasm_type` (267) + the
  `pushes=[infer...]` bridges (partition the 828 emit_raw! first) + the 4-way "MUST agree" resolver dup + 5 coercion
  ladders + 11 flow generators + 3 phi-byte-inspection copies + manual br-depths (→ symbolic Labels) + compile_value's
  byte-inspecting constant emitters. convert_type! gains the NET-NEW box/unbox arms (needs B's rep); numeric widening
  splits into `coerce_numeric!`. **Gate = CORRECTNESS (differential native-vs-wasm + Pkg.test + fuzzer: Union/
  heterogeneous-tuple/interp/branch-heavy) — NOT byte-identity.** This loop DELETES the brittle byte-inspecting path;
  the output bytes SHOULD change. Don't preserve `compile_value`'s old shape to keep the migration baseline stable
  (Dale 2026-06-29: byte-identity was a migration-loop net, not the parity gate — delete brittle code, verify by correctness).
- **Loop D — strict-by-default + total loud-reject + builder-parity finish.** Delete the 2 escape hatches
  (entry-permissive + must-execute, diagnostics.jl) → strict ON (P12/P15); typed emitters → delete RawBytes.
  PREREQ: throw-arms compile to CATCHABLE wasm exceptions (Loop 0's payload tag) or must-execute deletion
  over-rejects 11/20 ordinary fns. Gate: fuzzer in a wasm-tools-ABSENT env.
- **Loop E — closures (first-class) + GC nominal hierarchy + dispatch table [largest delta, LAST].** dart
  ClosureRepresentation + class-info GC model + classId+offset dispatch table; delete the flat-closure/no-vtable
  model, the 5 field-type derivation trees, the O(n) if-chain dispatch + dormant FNV dispatch.jl. Depends on all keystones.

**Deferred (off critical path):** strings i16/class-struct (F7/F18/B8, after B); EH full driver (B7/P4/P8, seeded by
Loop 0); Float16 (F26); F30 linear memory (out-of-subset); deeper lattice (F8/F22/F23). The #1 silent-wrong
filtered-fold (`sum(x for x in xs if c)→0`, FilteringRF) — fix once Loop C's typed channel lands (it's a typing/phi issue).

## ▶ START HERE: **Loop A (FINISH)** — wire wasm_subtype into the validator. Then Loop 0 banking, then B → B′ → F3-L2 → C → D → E.
