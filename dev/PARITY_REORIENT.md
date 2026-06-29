# WasmTarget → dart2wasm parity — REORIENTED loop sequence (2026-06-29 discovery swarm)

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

## ▶ LIVE STATUS (2026-06-29) + the one REVISION the build surfaced
✅ **Loop A DONE** (5fd44ce). ✅ **Loop 0 partial** — P13 (bf864a2) + F17 (ad7b0fa) banked; Int128-div + EH-tag
DEFERRED (sound-today, off critical path; do EH-tag right before Loop D). 🔄 **Loop B started** — B1 het-tuple i31
truncation fixed (811100e).

**★ REVISION (Dale's "fundamental-first / combine-loops" steer, build-surfaced):** Loop B's box-rep is largely
ALREADY in place (the numeric box subtypes `$JlBase` via set_struct_supertypes!; B1 fixed truncation). The remaining
Loop B **distinguishability is NOT a box problem — it's the typed VALUE CHANNEL (Loop C core).** Probe-proven: a
multi-member-Union SSA value is stored in a COLLAPSED-NUMERIC local (I32), unboxing it + dropping its classId at
allocation, so `isa` hits a "numeric → always true" shortcut (`_compile_call_isa` calls.jl:1323-1352). dart never
unboxes before a type-test. ⇒ **Loop B distinguishability + Loop C channel-core COMBINE; the channel-core is PULLED
FORWARD as the fundamental** (it unlocks B2 distinguishability AND B′ collections). Full trace: `dev/LOOP_B_DESIGN.md`.

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
