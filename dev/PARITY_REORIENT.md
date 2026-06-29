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

## THE SEQUENCE (dependency-ordered)
- **Loop 0 — free soundness banking** (small, independent, FIRST; de-risks A). Adopt: always-on cast verify,
  saturating-trunc struct, dedicated exception tag. Delete/add: ref.cast `target⊄input` reject (validator.jl:701,
  P13); typed TruncSat (statements.jl:3328, F17); emit_int128_div/rem (calls.jl:4395, F10); **EH tag with AnyRef
  PAYLOAD + value-carrying throw** (pulled forward — Loop D blocks on it). Gate: fuzzer + Pkg.test.
- **Loop A (FINISH) — wire `wasm_subtype` into the LIVE validator [KEYSTONE #1, THE FIRST ACTIONABLE LOOP].**
  The lattice exists but the validator is STILL PERMISSIVE: validator.jl:84/441/491/530 call
  `wasm_types_assignable` (:147), the struct (validator.jl:42) has no `mod`. Add `mod`, thread from InstrBuilder,
  replace the 4 calls with `wasm_subtype`, delete the permissive helper + `_is_ref_type` (B6), add the ref.cast
  reject. **GATE (critique §4 — byte-identity WON'T catch this):** compile_value builds the validator with no mod
  → the hot path silently runs the degraded `mod===nothing` relation (can't resolve ConcreteRef supertype chains).
  Assert mod-non-nothing on non-trivial paths OR fail loud + a differential test injecting a known-bad ConcreteRef
  subtype flow, asserting reject WITH mod threaded. Gates B/C/D soundness.
- **Loop B — ONE classId box for ALL dynamic/Union/Any [KEYSTONE #2, #1 functional gap].** Adopt dart `boxedClasses`
  `{classId:i32@0, value@1}`, classId = real Julia-type DFS id, discrimination = `struct_get classId`. Delete: the
  i31 family (types.jl:400-432 + calls.jl:2851/6144 + stackified.jl:94-156, F31), `emit_box_type_id!` WASM-type
  keying (P1 — Bool/Int8/Int16/Int32/Char collapse to Int32's id!), the union {typeId,tag,value} 3-field + per-union
  tag (unions.jl), the disjoint registry dicts. **Decide the identityHash/objectid slot in B's layout NOW.** Gate:
  the boxed-DISTINGUISHABILITY MATRIX over {Bool,Int8,Int16,Int32,Char,Int64,Float64} (explicit fixture, not fuzzer
  luck) + heterogeneous-Union/Vector{Any}/boxed-===/objectid set.
- **Loop B′ — collection element boxing** (critique add; was buried in E). Vector{Any} / heterogeneous Tuple /
  Dict-value store classId-boxed elements through the SAME rep → closes the abstract-Dict ×10 (#1 fuzzer) cluster.
  Needs no closures; rides right after B, before C's broad sweep.
- **F3 L2 — typed `Box{contents}` cell** (L0/L1 done; AFTER Loop B — it consumes the canonical box, else its
  hard-gated adversarial set re-verifies twice). The smallest self-contained proof of the typed channel. spec dev/F3_LOOP.md.
- **Loop C — typed value channel + convertType funnel + flow/phi/Label dedup [KEYSTONE #3, biggest deletion].**
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
