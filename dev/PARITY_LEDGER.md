I'll write the parity ledger from the 12 audit entries. Let me note the audit JSON contains entries for 12 dimensions; I'll preserve every file:symbol citation and structure it as requested.

# WasmTarget → dart2wasm Production-Parity Gap Ledger

**Mission:** Full 1:1 dart2wasm *production* parity for WasmTarget (WT) — not merely "passes the tests," but matching dart2wasm's compiler-infrastructure shape: one principled coercion primitive, one subtype lattice, one uniform value/dispatch representation, one validation discipline, and a total loud-reject contract.

**The two oracles:**
- **dart2wasm = HOW** (the architecture oracle): the reference design for *how* a WasmGC compiler should be structured (convertType, isSubtypeOf, classId+offset dispatch, typed Instruction hierarchy, Label-based control flow). Citations are to `pkg/dart2wasm/lib/*.dart` and `pkg/wasm_builder/lib/src/*.dart`.
- **Julia suite + differential fuzzer = VERIFICATION** (the correctness oracle): `Pkg.test()`, `test/fuzz/*`, `FINDINGS.md`, tolerance-based differential testing against native Julia. dart2wasm tells us the right shape; the Julia oracle tells us whether a given WT lowering is *faithful*.

**Date:** 2026-06-29

---

## OVERALL VERDICT

WT is **architecturally close but not yet at production parity** with dart2wasm. The instruction IR, control-flow relooper, numerics, exceptions, GC object model, and diagnostics are all dart2wasm-shaped and broadly complete (8 of 12 dimensions verdict "close"), and in several places WT *exceeds* dart2wasm (strict-by-default loud-reject, an external `wasm-tools` revalidation gate, 8 int widths + Int128, catchable DivideError). The four dimensions with verdict **significant-gap** are the real frontier and they cluster around **one root cause: WT lacks dart2wasm's single uniform value representation and its single coercion funnel.** Concretely: (1) Union/dynamic boxing is split across three divergent, partly-unsound schemes (numeric-only Union collapses to a lossy unboxed primitive — the confirmed #1 gap); (2) there is no `convertType` equivalent, so coercion is copy-pasted across 5+ drifting ladders; (3) closures are not first-class and mutated captures have no by-ref model; (4) strings use a single mutable i8 representation with no class wrapper. Compounding all four: WT's principled subtype lattice (`wasm_subtype`) and live operand-stack validator both *exist* but are **wired in to almost nothing** — the validator runs at `strict=false` everywhere and uses a permissive any-ref-to-any-ref relation, so WT's flagship "compiled ⟹ faithful" contract leans on an *optional* external binary. Closing the boxing/coercion/lattice trio would simultaneously retire most of the bloat dimensions, because the duplication exists precisely *because* there is no single funnel.

---

## PRIORITIZED GAP TABLE

Order: high-severity **functional** first, then **production**, then **bloat** (severity-descending within each).

| id | dimension | kind | severity | effort | one-line |
|----|-----------|------|----------|--------|----------|
| F1 | Boxing/dynamic | functional | high | large | Numeric-only Union collapses to lossy unboxed primitive (Int 1 / Float 1.0 indistinguishable) — the confirmed #1 gap |
| F2 | Closures | functional | high | large | No first-class closure value: closure called indirectly / escaping into abstract slot has no vtable/call_ref fallback |
| F3 | Closures | functional | high | large | No capture-by-ref: every closure field is immutable, no `Core.Box`/Context — mutated captures not observed |
| F4 | Type lattice | functional | high | medium | `wasm_subtype` ignores declared supertype chain — any two concrete structs deemed mutual subtypes (nominal-blind) |
| F5 | Exceptions | functional | high | medium | Thrown payload dropped on dominant `:invoke` path — `catch e; e.code` reads the type default, not the real value |
| F6 | Validation | functional | high | medium | Live validator uses permissive any-ref↔any-ref; the existing `wasm_subtype` lattice is not wired in (GC ref-mismatch class unchecked) |
| F7 | Strings | functional | high | large | Single i8 UTF-8 rep (no i16/per-codepoint) — root of SubString/unicode/codeunit FINDINGS cluster |
| F8 | Type lattice | functional | medium | large | No structural/field/element subtyping and no field-mutability variance |
| F9 | Boxing/dynamic | functional | medium | medium | Nullable-builtin (`Union{Nothing,Int}`) uses a different shape than dart2wasm's single boxed-int class |
| F10 | Numerics | functional | medium | large | Int128/UInt128 div/rem/checked-arith all loud-rejected (WT-original coverage hole) |
| F11 | Numerics | functional | medium | small | `cttz_int`/`ctpop_int` lack Int128 branch (only `ctlz` guarded) — Int128 trailing_zeros/count_ones broken |
| F12 | Dynamic dispatch | functional | medium | large | Live dispatch is single-arg only (`length(absp)==1`); Julia is multiple-dispatch |
| F13 | Dynamic dispatch | functional | medium | large | Live dispatch is O(n) inline if-chain per call site, no shared classId+offset table |
| F14 | GC structs/arrays | functional | medium | medium | No packed i8/i16 numeric arrays — Vector{Int8/Int16/UInt16} widened to i32 (2-4× memory) |
| F15 | GC structs/arrays | functional | medium | medium | No identity-hash field; objectid loud-rejected (blocks IdDict/objectid-keyed Dict) |
| F16 | GC structs/arrays | functional | medium | large | Rec-group/self-ref handling depth-capped & ad-hoc; mutually-recursive user structs loud-rejected |
| F17 | Instruction IR | functional | medium | small | No typed IR for saturating trunc (0xFC 0x00-07); the one needed is spliced via RawBytes bridge (validator-blind) |
| F18 | Strings | functional | medium | medium | JS-string-builtins path one-directional & incomplete; can't round-trip JS→Julia strings |
| F19 | Control flow | functional | medium | large | No general relooper: irreducible/multi-entry CFG silently mis-nests, no loud-reject |
| F20 | Control flow | functional | medium | medium | Loop-header detection index-order-based & inconsistent; existing dominator pass not reused |
| F21 | Coercion | functional | low | medium | No `instantiateDummyValue` for non-nullable ref dead-arm targets (narrower contract) |
| F22 | Type lattice | functional | low | medium | No function-type subtyping (contravariant in / covariant out) |
| F23 | Type lattice | functional | low | medium | Union join is ad-hoc/lossy — jumps straight to AnyRef, no lattice-meet on eq/struct |
| F24 | Strings | functional | low | small | Literal emission lacks lazy/data-segment threshold + per-codepoint width policy |
| F25 | Strings | functional | low | medium | No const-folded / arity-specialized interpolation; more alloc + larger uncompilable surface |
| F26 | Numerics | functional | low | medium | Float16 mis-typed (no F16 case, picks F64 ops on i31 value) — silent mis-emit not loud-reject |
| F27 | Numerics | functional | low | small | `fptosi/fptoui` trap (vs dart2wasm saturating) — uncatchable trap, not InexactError |
| F28 | Numerics | functional | low | medium | `fma_float` = mul+add (two roundings) — silent precision divergence from IEEE fma |
| F29 | Dynamic dispatch | functional | low | medium | No optional binary-search/polymorphic-specialization dispatch tier |
| F30 | Instruction IR | functional | low | large | Whole linear-memory load/store/size/grow family absent (by-design out-of-subset; flag MemoryOffsetAlign abstraction) |
| F31 | Coercion | functional | medium | medium | Non-canonical boxing: i31 vs `{typeId,value}` box not interchangeable — unbox can mis-decode |
| P1 | Boxing/dynamic | production | high | large | Three disjoint discrimination schemes (per-union local tag, dead typeId placeholder, wasm-keyed typeId) vs one global classId |
| P2 | Type lattice | production | high | medium | `wasm_subtype` is nullability-blind — nullable ref accepted into non-null slot (soundness hole) |
| P3 | Type lattice | production | high | medium | Live validator uses permissive assignable, not `wasm_subtype` — accepts wrong concrete struct / cross-hierarchy ref |
| P4 | Exceptions | production | high | large | Exception object in ONE module-wide global ($current_exn); nested throw-in-finally overwrites → wrong exception propagated |
| P5 | Validation | production | high | large | Strict-reject not total: ~57 raw UNREACHABLE sites, ~20 silent-trap stubs (Cat C) → compile-clean-then-trap |
| P6 | Diagnostics | production | high | large | Same as P5 from diagnostics view: silent-trap-stub class violates "compiled ⟹ faithful" |
| P7 | Exceptions | production | medium | small | $current_exn aliases the *first* mutable-anyref global — collides with any unrelated user global |
| P8 | Exceptions | production | medium | medium | catch_all-only + static ref.cast: wrong concrete type traps uncatchably (escapes try semantics) |
| P9 | Coercion | production | medium | medium | `ref.as_non_null` implemented but never called; every nullable→non-null narrowing emits heavier ref.cast |
| P10 | Boxing/dynamic | production | medium | medium | No uniform dummy-value synthesis for dead union/ref arms (ad-hoc null+tag is itself a mismatch source) |
| P11 | Control flow | production | high | medium | Manual numeric br-depth math (off-by-one = well-typed wrong branch) vs symbolic Labels |
| P12 | Control flow | production | medium | medium | All flow generators built strict=false → validator never gates control flow (the most imbalance-prone code) |
| P13 | Validation | production | high | small | No ref.cast soundness check (target⊄input not rejected) — most common GC unsoundness, only caught by external tool |
| P14 | Validation | production | medium | medium | No non-defaultable-local-init tracking (get-before-set of non-null ref → invalid wasm) |
| P15 | Validation | production | medium | medium | Builder validator at strict=false on all main paths → records errors but never acts; near dead-weight |
| P16 | Validation | production | medium | medium | wasm-tools gate is a SILENT no-op if binary absent → effectively no operand-level gate in such envs |
| P17 | Validation | production | medium | medium | Two strict escape hatches (non-TRIM dependency downgrade; must-execute gating) re-open silent-trap hole |
| P18 | GC structs/arrays | production | high | medium | struct/array field type passed by caller, not derived from registered type — wrong field idx/type validator-invisible |
| P19 | Dynamic dispatch | production | medium | small | Dispatch-miss = bare unreachable, no MethodError-equivalent/diagnostic (vs noSuchMethod) |
| P20 | Dynamic dispatch | production | medium | medium | Dormant hash-dispatch hand-counts br-depths/byte-splices (latent off-by-one in untested-in-prod code) |
| P21 | Coercion | production | low | small | No `needsConversion` gate; each ladder re-derives no-op short-circuit differently (redundant/double emit risk) |
| P22 | Instruction IR | production | low | medium | RawBytes escape hatch keeps IR non-total; opaque bytes bypass IR-level validation |
| B1 | Coercion | bloat | high | large | No single convertType — 5+ divergent inline coercion ladders that provably drift |
| B2 | Control flow | bloat | high | large | 3+ parallel flow generators + phi-store logic copy-pasted across 5 sites; helpers defined 3× |
| B3 | GC structs/arrays | bloat | high | large | No nominal Wasm struct subtype hierarchy for user types — abstract fields fall to StructRef/AnyRef needing cast-on-read |
| B4 | Dynamic dispatch | bloat | high | large | Dormant FNV-1a hash-table dispatch subsystem (~1100 lines) never produced by real pipeline |
| B5 | Boxing/dynamic | bloat | medium | medium | Box/unbox logic duplicated/divergent across ~10 sites; needs_anyref_boxing not consulted in SSA-value branch |
| B6 | Type lattice | bloat | medium | medium | NonNullAbstractRef second-class (MethodError in validator); dual-hierarchy + dead HeapType/RefTypeGC debt |
| B7 | Exceptions | bloat | medium | large | ~700-line try/catch driver of per-shape fuzzer-gap patches vs two compact dart2wasm visitors |
| B8 | Strings | bloat | medium | large | Three-layer hand-written string runtime (codegen + interpreter overlay + runtime/stringops.jl) vs library-code strings |
| B9 | GC structs/arrays | bloat | medium | large | Struct registration = 700-line elseif tree, ~5 near-dup copies; source of carve-outs |
| B10 | Control flow | bloat | medium | large | Byte-inspection of emitted phi bytes (LEB-decode/sniff) inside flow lowering (uses emit_raw! strict=false) |
| B11 | Closures | bloat | medium | medium | No capture-analysis pass; ad-hoc is_compiled_closure boolean + `val.n` vs `val.n-1` shims at ~6 sites |
| B12 | Numerics | bloat | low | medium | int128.jl repeats raw local-index bookkeeping per emitter (vs addLocal-style + extract128! helper) |
| B13 | Dynamic dispatch | bloat | medium | medium | Per-branch ad-hoc coercion vs principled LUB call_indirect signature (_computeSignature) |
| B14 | Instruction IR | bloat | low | medium | Generic NumOp(UInt8) collapses ~150 ops + ref.eq into one untyped struct (weak IR diagnostics) |
| B15 | Exceptions | bloat | low | medium | try_table catch-clause family half-wired (catch_ref/throw_ref!/rethrow_! exist but unused) |
| B16 | Coercion | bloat | low | small | Unbox always ref.casts before struct_get even when source already the box type (redundant) |
| B17 | Diagnostics | bloat | low | small | Errors source-attributed but not how-to-rewrite oriented; hint suggests disabling the gate |

---

## A. FUNCTIONAL GAPS

### F1 — Numeric-only Union collapses to a lossy unboxed primitive *(high, large)* — **THE #1 GAP**
`Union{Int64,Float64}` becomes raw `f64`, so `Int 1` and `Float 1.0` are indistinguishable at runtime; the i64 arm is silently `f64.convert`-ed (`src/codegen/values.jl:322-323`). The value-type resolver's all_numeric_u branch (`src/codegen/types.jl:1886-1893`) does **not** consult WT's own `needs_anyref_boxing` predicate (`src/builder/types.jl:481-495`) that already flags exactly this case — producing the documented "expected f64, found i64" validation failure.
- **wt_files:** `src/codegen/types.jl`, `src/builder/types.jl`, `src/codegen/values.jl`, `test/fuzz/FINDINGS.md`
- **dart2wasm_ref:** `translator.dart:convertType` (L854-862 box stamps `info.classId`) + `boxedClasses` (L202-205) + `class_info.dart:FieldIndex.boxValue/classId` (L27-28)
- **Do:** box each numeric arm into a classId-tagged box (boxedIntClass vs boxedDoubleClass); make `get_concrete_wasm_type` consult `needs_anyref_boxing` so value-type and slot-type agree.

### F2 — No first-class closure value *(high, large)*
A closure stored in an abstract `::Function` field/var and called indirectly has no analogue; WT relies entirely on Julia monomorphizing to `:invoke` (`src/codegen/calls.jl:6040`). When the callee stays abstract (escapes into a heterogeneous container, runtime-selected, ODEFunction/predicate field), WT stubs `unreachable`. `FINDINGS.md:1048-1049` (param-capturing rhs closure as ODEFunction field) and `:871` (higher-order fkeep!/ftranspose!) document this — the single biggest architectural delta.
- **wt_files:** `src/codegen/calls.jl`, `src/codegen/structs.jl`, `src/codegen/dispatch.jl`
- **dart2wasm_ref:** `closures.dart:45` ClosureRepresentation; `:267` _makeClosureStruct; `:106` fieldIndexForSignature (vtable call_ref ABI)
- **Do:** build a closureStruct {classID, identity-hash, context, vtable} + per-signature vtable with call_ref entries; fall back to it when inference leaves the call abstract.

### F3 — No capture-by-ref for mutated captures *(high, large)*
Every closure field is laid out IMMUTABLE (`src/codegen/structs.jl:123` `FieldType(wasm_vt, false) # immutable for closures`); zero `Core.Box` handling. A closure mutating a captured variable (or sibling closures sharing+mutating one capture) cannot observe writes. `FINDINGS.md:333-341` records a bond-capturing `do t … end` closure that captures+mutates a Vector and traps.
- **wt_files:** `src/codegen/structs.jl`, `src/codegen/calls.jl`
- **dart2wasm_ref:** `closures.dart:1016` Capture (`written` flag); `:1112-1118` buildContexts mutable context fields
- **Do:** model `Core.Box` / mutable heap Context fields; written captures go in a mutable context, never-written may localize.

### F4 — `wasm_subtype` ignores the declared supertype chain *(high, medium)*
`_gc_kind` collapses EVERY `ConcreteRef` to kind `:struct` (or `:array`), so the struct-vs-struct branch (`src/codegen/values.jl:219`) returns TRUE for ANY two concrete structs regardless of relationship — over-permissive and unable to recognize a genuine declared subtype. `supertype_idx` exists on StructType but is write-only at serialization (`src/builder/instructions.jl:1469`).
- **wt_files:** `src/codegen/values.jl`, `src/builder/types.jl`, `src/builder/instructions.jl`
- **dart2wasm_ref:** `type.dart:DefType.isSubtypeOf` (621-624) + `StructType.isStructuralSubtypeOf` (731-744)
- **Do:** make `wasm_subtype` walk `supertype_idx` recursively (dart2wasm DefType.isSubtypeOf).

### F5 — Thrown exception payload dropped on the dominant path *(high, medium)*
The `compile_invoke` arm for throw/BoundsError/KeyError/ArgumentError/MethodError stashes a DEFAULT struct (`struct_new_default!`, `src/codegen/invoke.jl:3803-3809`); the throw/rethrow/_throw_argerror arm stashes `ref.null any` (`invoke.jl:3553-3558`). Only `compile_call`'s `throw(obj)` (`src/codegen/calls.jl:5756-5759`) preserves the real value — but optimized IR usually emits `:invoke`, so the value-losing paths dominate. `try …; throw(MyErr(42)); catch e; e.code; end` reads the type default. Unverified-broken (no test reads a caught payload; `runtests.jl:5194` only catches-and-returns a constant).
- **wt_files:** `src/codegen/invoke.jl`, `src/codegen/calls.jl`
- **dart2wasm_ref:** `code_generator.dart:visitThrow` (2911-2919)
- **Do:** compile+stash the real exception object on every throw path, not just the `compile_call` one.

### F6 — Live validator can't catch GC ref-type mismatches *(high, medium)*
The live operand-stack validator uses permissive `wasm_types_assignable` (`src/builder/validator.jl:147-154`) where `_is_ref_type(a) && _is_ref_type(b) ⇒ true`, so it cannot catch struct $A where struct $B is expected, or a bad ref.cast input. The matching principled lattice `wasm_subtype` (`src/codegen/values.jl:165`, "Mirrors dart2wasm HeapType.isSubtypeOf") sits unused right next to the validator.
- **wt_files:** `src/builder/validator.jl`, `src/codegen/values.jl`
- **dart2wasm_ref:** `instructions.dart:_checkStackTypes` (:257 isSubtypeOf) + `_verifyCast` (:1132)
- **Do:** wire `wasm_subtype` into the validator (this also resolves P3).

### F7 — Single i8 UTF-8 string representation *(high, large)*
WT has only one internal rep `(array (mut i8))` (`src/codegen/types.jl:986`); the i16 array is JS-boundary-only. Storing all unicode as packed UTF-8 i8 is the ROOT of the SubString/unicode FINDINGS cluster: char-vs-byte indexing hand-contorted (`FINDINGS.md:197-200`), `codeunit(::SubString)` returns 0 (`src/codegen/interpreter.jl:445`), unicode Char tables absent.
- **wt_files:** `src/codegen/strings.jl:16`, `src/codegen/types.jl:986`, `src/codegen/interpreter.jl:445`, `test/fuzz/FINDINGS.md:56`
- **dart2wasm_ref:** `constants.dart:visitStringConstant:522` + `kernel_nodes.dart:oneByteStringClass/twoByteStringClass:47-50` + `sdk/.../string.dart:1143,1556`
- **Do:** add a TwoByteString-style i16 rep selected per-codepoint (index==codepoint for the wide class).

### F8 — No structural/field/element subtyping & no field-mutability variance *(medium, large)*
`FieldType{valtype,mutable_}` exists (`src/builder/types.jl:108-113`) but there is NO `isSubtypeOf` for fields/structs/arrays — `wasm_subtype` stops at the abstract kind. WT cannot validate that a declared subtype's fields structurally extend the supertype's, nor immutable-covariance/mutable-invariance.
- **wt_files:** `src/codegen/values.jl`, `src/builder/types.jl`
- **dart2wasm_ref:** `type.dart:StructType/ArrayType.isStructuralSubtypeOf` (731-784) + `FieldType.isSubtypeOf` (821-830)

### F9 — Nullable-builtin uses a non-uniform shape *(medium, medium)*
`Union{Nothing,T}→T` (`src/codegen/unions.jl:get_nullable_inner_type`, `types.jl:1872-1875`) works for ref T, but for primitive T (`Union{Nothing,Int64}`) there is no nullable-i64; the lack of a uniform boxed-int means nullable primitives and union-member primitives use different shapes.
- **wt_files:** `src/codegen/unions.jl`, `src/codegen/types.jl`
- **dart2wasm_ref:** `translator.dart:translateStorageType` nullable-builtin → `boxedBuiltin.nullableType` (L570-573)

### F10 — Int128/UInt128 div/rem/checked-arith loud-rejected *(medium, large)*
`src/codegen/calls.jl:4395-4404` rejects sdiv/udiv/srem/urem + checked div for 128-bit; `_compile_call_checked_mul` (`calls.jl:570-575`) and checked add/sub (`:4660`, `:4722`) explicitly reject 128-bit. WT-original territory (dart2wasm has no Int128), a coverage hole in WT's *own* advertised 128-bit support (add/sub/mul/shift/bitwise/compare work).
- **wt_files:** `src/codegen/calls.jl`, `src/codegen/int128.jl`
- **dart2wasm_ref:** no model — WT must self-host correctness (`intrinsics.dart:25` intType is i64-only)

### F11 — `cttz_int`/`ctpop_int` lack the Int128 branch *(medium, small)*
`src/codegen/calls.jl:5242` (cttz) and `:5246` (ctpop) unconditionally emit `is_32bit ? I32_* : I64_*` with no `is_128bit` branch, whereas `ctlz_int` (`:5235-5240`) dispatches to `emit_int128_ctlz`. Int128 trailing_zeros/count_ones → struct-ref value meets i64.ctz/popcnt → validation failure. The asymmetry (ctlz guarded, siblings not) is also a soundness smell.
- **wt_files:** `src/codegen/calls.jl`
- **dart2wasm_ref:** `intrinsics.dart:172-185` (all-widths-handled discipline)
- **Do:** add `is_128bit` branches mirroring `ctlz_int`. **Cheapest functional win in the ledger.**

### F12 — Live dispatch is single-arg only *(medium, large)*
`src/codegen/calls.jl:1580` `length(absp) == 1 || return nothing`; any residual call needing 2+ runtime-typed args falls to unreachable/loud-reject. Julia is fundamentally multiple-dispatch. (The dormant hash-table path supported multi-arg tuples — capability on the dead path.)
- **wt_files:** `src/codegen/calls.jl`
- **dart2wasm_ref:** `dispatch_table.dart:SelectorInfo` (single-receiver; WT needs N-arg)

### F13 — Live dispatch is O(n) inline if-chain, no shared table *(medium, large)*
`_try_inline_typeid_dispatch` re-emits an `i32.eq` chain inline at EVERY call site, no shared table. dart2wasm `_virtualCall` is O(1): `struct_get classId` + `i32_add offset` + one `call_indirect` into a bin-packed table. The DFS typeId ranges WT already computes (`src/codegen/types.jl:assign_type_ids!`) are the exact substrate for a classId+offset table.
- **wt_files:** `src/codegen/calls.jl`
- **dart2wasm_ref:** `code_generator.dart:_virtualCall` (2113-2119)

### F14 — No packed i8/i16 numeric arrays *(medium, medium)*
WT only packs UInt8/String to i8 (`src/codegen/types.jl:989,955`); every other small int (Int8/Int16/UInt16) is widened to i32 via `julia_to_wasm_type` (`src/builder/types.jl:305`), costing 2-4× memory and diverging from byte-exact representation.
- **wt_files:** `src/codegen/types.jl`, `src/builder/types.jl`
- **dart2wasm_ref:** `translator.dart:185-188` (PackedType) + `intrinsics.dart:509-541,615-669` (packed array_get_u/get_s/set)

### F15 — No identity-hash field; objectid loud-rejected *(medium, medium)*
WT's universal layout has typeId at field 0 only, no identity slot, and loud-rejects `jl_object_id/objectid` as `:value_stub` (`src/codegen/statements.jl:2701-2708`). Blocks IdDict/objectid-keyed-Dict/object-identity patterns.
- **wt_files:** `src/codegen/structs.jl`, `src/codegen/statements.jl`
- **dart2wasm_ref:** `class_info.dart:377-378` (identityHash field) + `intrinsics.dart:740-760,1314-1345`

### F16 — Rec-group/self-ref handling depth-capped & ad-hoc *(medium, large)*
`is_self_referential_type` only handles Vector{T}/Union{Nothing,T} self-fields (`src/codegen/structs.jl:162`); a separate `ensure_nominal_struct_types!` pass (`src/builder/instructions.jl:497`) retro-groups structurally-identical structs; mutually-recursive graphs are loud-rejected (`structs.jl:194`); a depth-120 cap aborts deep descent (`structs.jl:199`).
- **wt_files:** `src/codegen/structs.jl`, `src/builder/instructions.jl`
- **dart2wasm_ref:** `type.dart:596-650` (DefType supertype/depth + serializeDefinition) + `class_info.dart:collect`

### F17 — No typed IR for saturating truncation *(medium, small)*
The 0xFC 0x00-07 trunc_sat family has no typed struct; the one WT needs (f64→i64 unsigned saturating) is spliced via `emit_raw!(b, UInt8[0xFC, 0x07])` at `src/codegen/statements.jl:3329` (comment: "no typed method → bridge") — LIVE output that bypasses both the typed IR AND the operand-stack validator.
- **wt_files:** `src/builder/instr_ir.jl`, `src/codegen/statements.jl`, `src/builder/instr_builder.jl`
- **dart2wasm_ref:** `instruction.dart:1456` (I32TruncSatF32S) .. `:1484`; builder `instructions.dart:2267` (i64_trunc_sat_f64_u)
- **Do:** add the 8 trunc_sat structs + emitters; retire the RawBytes splice (also helps P22).

### F18 — JS-string-builtins path one-directional & incomplete *(medium, medium)*
Only `wasm:js-string.fromCharCodeArray` is imported (`src/codegen/strings.jl:43,277`); the encode direction is a placeholder (`encode_idx = decode_idx`, `strings.jl:49`); `emit_js_to_jl_string!` still references legacy wasm:text-encoder (`strings.jl:194`). WT can't round-trip JS strings into Julia strings (DOM-text scenarios).
- **wt_files:** `src/codegen/strings.jl:49`, `:194`, `:277`
- **dart2wasm_ref:** `js/runtime_blob.dart:jsStringPolyfill:81-93` + `constants.dart:visitStringConstant(jsCompatibility):513-520`

### F19 — No general relooper / irreducible-CFG handling *(medium, large)*
Back-edge = `succ<=block_idx` (`src/codegen/stackified.jl:296`), loop nesting by block order assume reducible diamonds; an irreducible region gives wrong nesting/br-depths silently, violating loud-reject-on-unsupported. Latent (Julia CFGs are reducible) but unguaranteed and unchecked.
- **wt_files:** `src/codegen/stackified.jl`
- **dart2wasm_ref:** `code_generator.dart` (no relooper; reducibility guaranteed by Kernel AST)

### F20 — Loop-header detection index-order-based & inconsistent *(medium, medium)*
`ctx.loop_headers` (`src/codegen/context.jl:689`) flags only GotoNode back-edges (misses GotoIfNot); the relooper uses `succ<=block_idx` (`stackified.jl:296`) which misclassifies forward jumps to lower-indexed blocks. The dominator code WT already has (`src/codegen/generate.jl:570` stmt_must_execute) is not reused.
- **wt_files:** `src/codegen/context.jl`, `src/codegen/stackified.jl`, `src/codegen/generate.jl`
- **dart2wasm_ref:** `code_generator.dart:visitWhileStatement/visitForStatement`
- **Do:** a dominator-based back-edge test would fix and unify both.

### F21 — Dead-arm dummy narrower than `instantiateDummyValue` *(low, medium)*
WT's dead-arm synthesis only ever produces `ref.null` and assumes a nullable slot (`src/codegen/values.jl:282-285`; `push_default!` `calls.jl:1638`); no prepared-dummy-instance path for a NON-nullable ref target.
- **wt_files:** `src/codegen/values.jl`, `src/codegen/calls.jl`
- **dart2wasm_ref:** `globals.dart:99` instantiateDummyValue

### F22 — No function-type subtyping *(low, medium)*
`FuncType` (`src/builder/types.jl:89-96`) has no subtype relation; `wasm_subtype` treats FuncRef as opaque top (`src/codegen/values.jl:179-182`). Lower severity because WT leans on call/call_indirect rather than typed funcref upcasts.
- **wt_files:** `src/codegen/values.jl`, `src/builder/types.jl`
- **dart2wasm_ref:** `type.dart:FunctionType.isStructuralSubtypeOf` (672-686)

### F23 — Union join is ad-hoc/lossy *(low, medium)*
`find_common_wasm_type/resolve_union_type` (`src/builder/types.jl:392-471`) hand-roll category buckets and bail to AnyRef for any heterogeneous mix; no lattice-meet returning the nearest common abstract supertype (struct/eq/any). `needs_anyref_boxing` (`types.jl:481-495`) is a further hand-tuned override.
- **wt_files:** `src/builder/types.jl`
- **dart2wasm_ref:** `translator.dart:convertType` (828-875) uniform isSubtypeOf-driven representation types

### F24 — String-literal emission lacks lazy/per-width policy *(low, small)*
WT always uses `array.new_data` for non-empty strings regardless of length (`src/codegen/values.jl:655-666`) and only writes raw UTF-8; the signed-LEB length was a latent miscompile hand-patched at `values.jl:661-665` (`FINDINGS.md:73`).
- **wt_files:** `src/codegen/values.jl:655`, `:732`
- **dart2wasm_ref:** `constants.dart:19` (maxArrayNewFixedLength=10000) + `:528-560` (lazy + per-width segment)

### F25 — No const-folded / arity-specialized interpolation *(low, medium)*
WT lowers `string(...)`/interpolation through generic overlays + runtime `str_concat/int_to_string/float_to_string`; markdown interpolation is a hard-coded special case (`src/codegen/calls.jl:2793`); `FINDINGS.md:401` integer/string %-formats trap.
- **wt_files:** `src/codegen/calls.jl:2793`, `src/runtime/stringops.jl:1`
- **dart2wasm_ref:** `code_generator.dart:visitStringConcatenation:2870-2905` (const-fold + stringInterpolate1..4)

### F26 — Float16 mis-typed *(low, medium)*
`julia_to_wasm_type` (`src/builder/types.jl:290-343`) has no Float16 case (falls to default), yet `arg_type === Float16` makes `is_32bit` true (`calls.jl:3935`) so float-op branches select F64 ops on a non-f64 value → type-confused emission. Effectively unsupported but NOT loud-rejected.
- **wt_files:** `src/codegen/calls.jl`, `src/builder/types.jl`, `src/codegen/types.jl`
- **dart2wasm_ref:** LOUD-REJECT discipline (`code_generator.dart:3658` UnsupportedError) — WT should reject, not mis-type

### F27 — `fptosi/fptoui` trap vs dart2wasm saturating *(low, small)*
`src/codegen/calls.jl:5619/5621` (and `_U` at `5630/5632`) emit trapping `I32/I64_TRUNC_F64_S`. Defensible (matches Julia's `fptosi` UB/trap contract) but the trap is uncatchable rather than surfacing as InexactError.
- **wt_files:** `src/codegen/calls.jl`
- **dart2wasm_ref:** `intrinsics.dart:102` (_toInt → i64_trunc_sat_f64_s), `:268`

### F28 — `fma_float` = mul+add (two roundings) *(low, medium)*
`src/codegen/calls.jl:5344-5346` compiles fma as MUL then ADD; `muladd_float` (`:5335-5339`) is correct but `fma_float` promises IEEE single-rounded. Silent numeric divergence (wasm has no scalar FMA).
- **wt_files:** `src/codegen/calls.jl`
- **dart2wasm_ref:** no fma model — flagged as soundness divergence vs Julia's fma contract

### F29 — No binary-search/polymorphic-specialization dispatch tier *(low, medium)*
WT's only inline form is the O(n) flat if-chain — no sorting/ranging, no table tier.
- **wt_files:** `src/codegen/calls.jl`
- **dart2wasm_ref:** `code_generator.dart:_polymorphicSpecialization`

### F30 — Whole linear-memory load/store/size/grow family absent *(low, large)*
WT has the Opcode constants (`src/builder/instructions.jl:58-67`) but zero structs/emitters. BY DESIGN out-of-subset (WT is pure-WasmGC). Flag the missing MemoryOffsetAlign immediate abstraction WT would need wholesale if linear memory ever enters scope.
- **wt_files:** `src/builder/instr_ir.jl`, `src/builder/instructions.jl`, `src/builder/instr_builder.jl`
- **dart2wasm_ref:** `instruction.dart:395` (MemoryOffsetAlign), `:415` (MemoryInstruction), `:428`..`:542`

### F31 — Non-canonical boxing: i31 vs box-struct not interchangeable *(medium, medium)*
WT boxes a numeric into a ref slot via TWO reps by site: `{typeId,value}` numeric-box (`get_numeric_box_type!`, `src/codegen/calls.jl:1622/6146/6164`) AND `ref.i31` (`calls.jl:6123/6126/2851/2853`). An unbox assuming one rep mis-decodes a value boxed by the other.
- **wt_files:** `src/codegen/calls.jl`, `src/codegen/values.jl`
- **dart2wasm_ref:** `translator.dart:856-870` (boxedClasses canonical box/unbox)

---

## B. BLOAT / ARCHITECTURE GAPS

### B1 — No single convertType *(high, large)* — **THE CENTRAL ARCHITECTURAL DIVERGENCE**
Coercion logic (upcast-free / downcast-ref.cast / box / unbox / extern↔any) is copy-pasted as 5+ divergent inline `(expected_wasm, actual_wasm)` elseif-ladders: `emit_return_coerced!` (returns, `src/codegen/values.jl:273`), `src/codegen/calls.jl:6058+` (args, 44+ elseif), `compile_new` (struct fields, `src/codegen/statements.jl` ~2200-2550), `emit_phi_local_set!` (locals, `src/codegen/flow.jl:414`), `coerce!` (dispatch, `calls.jl:1614`). dart2wasm routes ALL 65 sites through ONE 33-line `convertType`. Per the v0.3.x PURE-* fix comments, these provably drift — a case fixed at the return site is not fixed at the arg/field/local site.
- **wt_files:** `src/codegen/values.jl`, `src/codegen/calls.jl`, `src/codegen/statements.jl`, `src/codegen/flow.jl`
- **dart2wasm_ref:** `translator.dart:convertType` (one fn, 65 call sites)
- **Do:** introduce one `convert_type!(b, from_wasm, to_wasm, mod)` funnel; route all 5 ladders through it.

### B2 — 3+ parallel flow generators; phi-store copy-pasted *(high, large)*
`generate_loop_code`/`generate_branched_loops`/`generate_stackified_flow`/`generate_nested_conditionals`/`generate_if_then_else`/`compile_ternary_for_phi`/`generate_and_pattern` (across `flow.jl`, `stackified.jl`, `conditionals.jl`) re-implement diamond/loop lowering with heuristic routing. Phi-store logic is copy-pasted across `emit_phi_local_set!` (`flow.jl:414`), `set_phi_locals_for_edge!` (`stackified.jl:915`), inline phi (`stackified.jl:1310`), ternary, and-pattern; `get_phi_edge_wasm_type/wasm_types_compatible` defined 3× (`flow.jl:268/366`, `stackified.jl:780/868`).
- **wt_files:** `src/codegen/flow.jl`, `src/codegen/stackified.jl`, `src/codegen/conditionals.jl`
- **dart2wasm_ref:** `code_generator.dart:branchIf/_conditional` (1384/1415) + visit{While,For,If,Switch}Statement

### B3 — No nominal Wasm struct subtype hierarchy for user types *(high, large)*
WT registers every concrete struct as a flat independent struct (`supertype_idx=nothing`) and reconstructs Julia's type relation with a parallel mechanism (a separate `$JlType` struct tree + DFS typeId integer-range checks, `src/codegen/types.jl:485` create_jl_type_hierarchy!). Abstract/interface-typed fields fall back to StructRef/AnyRef and require a runtime ref.cast on every read (`src/codegen/structs.jl:627,730-745`), losing the static typing dart2wasm preserves via `repr` upper-bounds.
- **wt_files:** `src/codegen/structs.jl`, `src/codegen/types.jl`, `src/builder/types.jl`
- **dart2wasm_ref:** `class_info.dart:_createStructForClass` + `_generateFields` + `ClassInfo.repr` (upperBound); `translator.dart:577`

### B4 — Dormant FNV-1a hash-table dispatch subsystem *(high, large)*
`src/codegen/dispatch.jl` (~1100 lines: build_dispatch_tables, emit_dispatch_call!, emit_dispatch_wrappers!, OverlayRegistry, emit_overlay_dispatch_call!, serialize_dispatch_tables) is wired into `src/codegen/compile.jl:1615` but NEVER produced by the real pipeline (`overlay_entries` always empty; megamorphic dispatch served by `_try_inline_typeid_dispatch`). Reachable only via synthetic `compile_module(...; overlay_entries=...)` unit tests (`runtests.jl:5337,5373`). No analogue in dart2wasm's design.
- **wt_files:** `src/codegen/dispatch.jl`, `src/codegen/compile.jl`
- **dart2wasm_ref:** `dispatch_table.dart:DispatchTable` (one table, no hashing)
- **Do:** either delete, or replace the live single-arg if-chain with a classId+offset table built from the existing DFS ranges (subsumes F12/F13).

### B5 — Box/unbox duplicated/divergent across ~10 sites *(medium, medium)*
`needs_anyref_boxing` is consulted at param/local/flow sites (`calls.jl:1344`, `context.jl:1296/1303/2079`, `flow.jl:323`, `compile.jl:90/1749/1988/2843/2951`) but NOT in `get_concrete_wasm_type`'s SSA-value branch (`types.jl:1886`); `emit_numeric_to_externref!/anyref!` (stackified.jl), `emit_wrap/unwrap_union_value` (unions.jl), per-site phi boxing (`stackified.jl:614-996`) each re-implement the box ladder.
- **wt_files:** `src/codegen/types.jl`, `src/codegen/calls.jl`, `src/codegen/stackified.jl`, `src/codegen/unions.jl`, `src/codegen/context.jl`
- **dart2wasm_ref:** `translator.dart:convertType` (828-875)

### B6 — NonNullAbstractRef second-class; dual-hierarchy + dead types *(medium, medium)*
`wasm_subtype` treats NonNullAbstractRef as only ===-equal (`values.jl:170`); `validator.jl`'s `_is_ref_type` has NO method for NonNullAbstractRef (`validator.jl:157-160`) → MethodError. The dual modeling (RefType enum = nullable shorthand, NonNullAbstractRef = ad-hoc non-null, ConcreteRef = only type with a real nullable bit, plus the entirely-dead HeapType/RefTypeGC pair `types.jl:147-181`) is debt vs dart2wasm's single RefType{heapType,nullable}.
- **wt_files:** `src/builder/types.jl`, `src/builder/validator.jl`
- **dart2wasm_ref:** `type.dart:RefType` (132-230, single nullable-carrying class) + `HeapType.nullableByDefault` (273)

### B7 — ~700-line try/catch driver of per-shape patches *(medium, large)*
`generate_try_catch_stackified` + `generate_branch_split_try` + `_emit_chain_levels` + has_merge/has_exit_branch/_arm_complex heuristics (`src/codegen/generate.jl:884-1568`), each annotated with a gap id (P2-batch16..25, 6d3a1788a329, …). dart2wasm's entire EH lowering is two compact visitors (visitTryCatch ~125 lines, visitTryFinally ~90). The accretion signals the global-stash + catch_all-only model does not compose.
- **wt_files:** `src/codegen/generate.jl`
- **dart2wasm_ref:** `code_generator.dart:visitTryCatch` (1158-1284) + `visitTryFinally` (1287-1380)

### B8 — Three-layer hand-written string runtime *(medium, large)*
`compile_string_concat_with_locals`/`compile_string_equal` (`src/codegen/strings.jl:466,530`) reached by ad-hoc name dispatch (`*` at `calls.jl:5693-5705`, `==` at `:3796`) + interpreter overlays (`interpreter.jl`) + `src/runtime/stringops.jl` (645 lines). dart2wasm has NO compiler-emitted string ops — only interpolation. The `calls.jl:5694` comment documents an `i64.mul on two string refs` validation failure from this routing fragility.
- **wt_files:** `src/codegen/strings.jl:466`, `:530`, `src/codegen/calls.jl:5693`, `src/runtime/stringops.jl:1`
- **dart2wasm_ref:** `code_generator.dart:visitStringConcatenation:2856`

### B9 — Struct registration = 700-line elseif tree, ~5 near-dup copies *(medium, large)*
`_register_struct_type_impl!`, `_register_struct_type_impl_with_reserved!`, `register_closure_type!`, `register_tuple_type!`, + temp-fields placeholder loop each re-derive Julia→Wasm field type inline (PURE-####/WBUILD-#### tags throughout). Source of the carve-outs (is_struct_type, _ARRAY_STRUCT_CARVEOUT, Dual/Partials/SparseMatrixCSC).
- **wt_files:** `src/codegen/structs.jl`, `src/codegen/types.jl`
- **dart2wasm_ref:** `translator.dart:493` translateType + `987` translateTypeOfField (single oracle); `class_info.dart:365` _generateFields

### B10 — Byte-inspection of emitted phi bytes inside flow lowering *(medium, large)*
`set_phi_locals_for_edge!` and inline phi LEB-decode `compile_phi_value` output (`stackified.jl:1035-1038,1370-1388`), sniff trailing EXTERN_CONVERT_ANY/leading REF_NULL (`stackified.jl:987-990,1326-1328,1399`), detect multi-value runs by re-parsing (`stackified.jl:1352-1364`; `flow.jl:600-642`) — using `emit_raw!` strict=false (`stackified.jl:361`), blinding the validator. The v0.4.0 InstrBuilder migration was meant to remove this.
- **wt_files:** `src/codegen/stackified.jl`, `src/codegen/flow.jl`
- **dart2wasm_ref:** `code_generator.dart:visitReturnStatement` (1540) + convertType

### B11 — No closure-capture analysis pass *(medium, medium)*
Capture handling scattered: is_closure_type heuristic (`structs.jl:68`), is_compiled_closure boolean threaded through CompilationContext (`context.jl:31`) with manual `val.n` vs `val.n-1` shims at ~6 sites (`context.jl:1762,1956,1975,2076`; `calls.jl:13,1340,1464`), + separate Therapy signal-capture special case (`context.jl:154-225`).
- **wt_files:** `src/codegen/context.jl`, `src/codegen/calls.jl`, `src/codegen/structs.jl`
- **dart2wasm_ref:** `closures.dart:1129` CaptureFinder; `:1074-1126` collectContexts/buildContexts

### B12 — int128.jl repeats raw local-index bookkeeping *(low, medium)*
Every emitter repeats the `length(ctx.locals) + ctx.n_params; push!(ctx.locals, T); builder_set_local_type!(b, i, T)` idiom inline (`emit_int128_add:20-30`, `emit_int128_mul:129-149`, ×14 functions); the field-extraction prologue is copy-pasted in ~10 emitters.
- **wt_files:** `src/codegen/int128.jl`
- **dart2wasm_ref:** `FunctionBuilder.addLocal` (via `translator.dart:858`, `intrinsics.dart:174`)
- **Do:** addLocal-style helper + `extract128!` helper.

### B13 — Per-branch ad-hoc dispatch coercion vs LUB signature *(medium, medium)*
WT ref.casts to the concrete type per branch and direct-calls the specialization's own signature, with hand-rolled `coerce!`/`push_default!` (`calls.jl:1614-1652`). dart2wasm computes a principled LUB Wasm signature across ALL targets (`_computeSignature/_upperBound`, `dispatch_table.dart:86-205`). WT has `wasm_subtype` but doesn't apply it to compute a join signature.
- **wt_files:** `src/codegen/calls.jl`
- **dart2wasm_ref:** `dispatch_table.dart:SelectorInfo._computeSignature / _upperBound`

### B14 — Generic NumOp collapses ~150 ops + ref.eq *(low, medium)*
`InstrIR.NumOp(op::UInt8)` (`src/builder/instr_ir.jl:26`) carries no per-op identity/type signature, so `mnemonic` prints "num 0x6a" (`instr_ir.jl:274`) not "i32.add"; typing/stack-effect lives in the validator's per-opcode dispatch (`src/builder/validator.jl`, ~65 ops). ref.eq is `NumOp(0xD3)`, a named class in dart2wasm. Debt, not a correctness gap.
- **wt_files:** `src/builder/instr_ir.jl`, `src/builder/instr_builder.jl`, `src/builder/validator.jl`
- **dart2wasm_ref:** `instruction.dart:1092` (I32Add), `:588` (RefEq), `:944` (I32Eqz)

### B15 — try_table catch-clause family half-wired *(low, medium)*
`catch_clause/catch_ref_clause/catch_all_ref_clause` + `throw_ref!/rethrow_!` exist (`src/builder/instr_builder.jl:291-315`, instr_ir.jl) but codegen NEVER uses them — every `try_table!` passes only `[catch_all_clause(0)]`; rethrow is a fresh `throw 0` reading the global (`invoke.jl:3548-3552`). Dead builder surface.
- **wt_files:** `src/builder/instr_builder.jl`, `src/builder/instr_ir.jl`, `src/codegen/invoke.jl`
- **dart2wasm_ref:** `instructions.dart:catch_/rethrow_` (460-495); `code_generator.dart:visitRethrow` (2921-2925)

### B16 — Unbox always ref.casts before struct_get *(low, small)*
WT unbox sites unconditionally `ref_cast!` before `struct_get!` (`values.jl:373-374` compile_condition_to_i32; `:510-511` PiNode), even when the local is already the box type. dart2wasm casts ONLY if `!from.heapType.isSubtypeOf(info.struct)` (`translator.dart:866`).
- **wt_files:** `src/codegen/values.jl`
- **dart2wasm_ref:** `translator.dart:866`

### B17 — Errors not how-to-rewrite oriented *(low, small)*
`WasmCompileError.showerror` (`src/codegen/diagnostics.jl:55`) prints kind/construct/julia_loc and the only hint is "pass strict=false to emit a runtime-trap stub" (`:60`) — i.e. it suggests turning OFF the soundness gate. No "unsupported because X; rewrite as Y." A missed differentiation opportunity (dart2wasm is terse too).
- **wt_files:** `src/codegen/diagnostics.jl`
- **dart2wasm_ref:** `translator.dart:502` (terse throw — WT could exceed)

---

## C. PRODUCTION-SOUNDNESS GAPS

### P1 — Three disjoint discrimination schemes vs one classId *(high, large)*
WT tagged-unions use a per-union-local sequential `tag` whose meaning is unstable across union types, AND a dead `typeId` field hardwired to 0 ("typeId (0 placeholder)", `src/codegen/unions.jl:215,227`); numeric boxes use a typeId keyed on the WASM type (`emit_box_type_id!`), so Bool/Int8/Int16/Int32/Char all collapse to the SAME typeId. dart2wasm uses ONE global DFS-numbered classId stamped on every instance and read uniformly.
- **wt_files:** `src/codegen/unions.jl`, `src/codegen/types.jl`
- **dart2wasm_ref:** `class_info.dart:FieldIndex.classId=0` (L27) + ClassInfoCollector DFS numbering (L432-689); `dispatch_table.dart` classId ranges (L380-451)

### P2 — `wasm_subtype` is nullability-blind *(high, medium)*
Honors nullability only through the `a===b` base case (`values.jl:166`); for two different ConcreteRefs or any abstract-kind branch the nullable flag is never compared, so a nullable ref is treated as a subtype of a non-nullable expectation. The RefType @enum has no non-null variant. A value that may be null can flow into a non-null slot undetected.
- **wt_files:** `src/codegen/values.jl`, `src/builder/types.jl`
- **dart2wasm_ref:** `type.dart:RefType.isSubtypeOf` (200-204) + `RefType.withNullability` (192-194)

### P3 — Live validator uses permissive assignable, not the lattice *(high, medium)*
`validate_gc_instruction!` (`src/builder/validator.jl:624-699`) accepts a wrong concrete struct, an arrayref where a structref is needed, or any cross-hierarchy ref — exactly the build-time errors dart2wasm catches. Two parallel notions (precise `wasm_subtype` used in 2 spots; permissive assignable everywhere in validation) is itself un-dart2wasm-shaped.
- **wt_files:** `src/builder/validator.jl`
- **dart2wasm_ref:** `instructions.dart:_checkStackTypes` (252-268) / `_verifyTypesFun` (276-294)
- **Do:** replace `wasm_types_assignable` with `wasm_subtype` (same fix as F6; gated by P2).

### P4 — Exception object in ONE module-wide global *(high, large)*
`ensure_exception_global!` returns the first mutable-anyref global module-wide (`src/codegen/generate.jl:762-773`), so the object is global, not per-throw/per-frame. Julia lowers `try…finally` to a catch region that runs the finalizer then `rethrow()` reading `$current_exn`; if the finalizer (or any catch body) contains its OWN throw-and-catch, it overwrites `$current_exn` before the outer rethrow → the outer propagates the WRONG exception. dart2wasm is immune (object lives on the wasm exception payload, popped to a frame-local at the catch).
- **wt_files:** `src/codegen/generate.jl`, `src/codegen/statements.jl`, `src/codegen/invoke.jl`
- **dart2wasm_ref:** `translator.dart:createExceptionTag` (481-491); `code_generator.dart:visitTryCatch` (1175-1229)
- **Do:** make the exception tag typed `[exception, stackTrace]` and `local_set` into per-frame locals at each catch.

### P5 — Strict-reject not total (~57 raw UNREACHABLE, ~20 silent-trap) *(high, large)*
`STRICT_MODE_PLAN.md`/`STRICT_MODE_INVENTORY.md` document ~57 raw `Opcode.UNREACHABLE` emit sites with only 20 routed through `emit_unsupported_stub!` and 12 through `record_unsupported!`. The boxing→dynamic-dispatch + Int128 + ':new of dynamic type' stub families (Category C, ~20 sites e.g. `calls.jl` typeId-dispatch-miss, `statements.jl:1785/1799`) take the SILENT unreachable path → compile-clean-then-trap, violating "compiled ⟹ faithful" for any reachable instance.
- **wt_files:** `src/codegen/diagnostics.jl`, `src/codegen/calls.jl`, `src/codegen/statements.jl`, `test/fuzz/STRICT_MODE_INVENTORY.md`
- **dart2wasm_ref:** `translator.dart:translateType` (:502) + `code_generator.dart:visitPatternSwitchStatement` (:3658)

### P6 — Silent-trap-stub class violates the contract (diagnostics view) *(high, large)*
Escaping/abstractly-called closures and mutated captures degrade to silent `unreachable` stubs (`FINDINGS.md:1048-1049`); `dispatch.jl` head comment shows call_indirect is named-function-only. No diagnostic in `src/codegen/diagnostics.jl` names "first-class closure value" or "mutated captured variable" as definite-unsupported the way struct-recursion is (`structs.jl:194-206` throws WasmCompileError for rec-group cycles).
- **wt_files:** `src/codegen/diagnostics.jl`, `src/codegen/calls.jl`
- **dart2wasm_ref:** `closures.dart:45` (value-form to detect+reject); contrast `structs.jl:194` named-error precedent
- **Do:** add named WasmCompileErrors for the silent-trap families (folds P5+P6 together).

### P7 — $current_exn aliases the first mutable-anyref global *(medium, small)*
`ensure_exception_global!` (`generate.jl:764-768`) reuses any existing mutable-anyref global; a program defining one for unrelated reasons would have it silently reused as the exception stash, corrupting both.
- **wt_files:** `src/codegen/generate.jl`
- **dart2wasm_ref:** `translator.dart:createExceptionTag` (485-490, dedicated tag via `m.tags.define`)
- **Do:** allocate a dedicated, named, exception-only global/tag. **Smallest production win in EH.**

### P8 — catch_all-only + static ref.cast traps uncatchably *(medium, medium)*
Catch is ALWAYS `catch_all` (`generate.jl:1014,…,2473`); the caught value is `global.get $current_exn` then static `ref.cast` to the SSA local's type (`src/codegen/statements.jl:676-685`). If the thrown object's concrete type differs from the catch local's inferred type, the ref.cast traps UNCATCHABLY — escaping try semantics. dart2wasm gates each downcast behind emitIsTest+br_if (`code_generator.dart:1190-1208`).
- **wt_files:** `src/codegen/statements.jl`
- **dart2wasm_ref:** `code_generator.dart:emitCatchBlock` (1179-1208)

### P9 — `ref.as_non_null` implemented but never called *(medium, medium)*
`ref_as_non_null!` (`src/builder/instr_builder.jl:328`) exists but no coercion path calls it; every nullable→non-null narrowing of the SAME heap type emits `ref_cast!` (`values.jl:301/312/314`; `calls.jl:6099/6105/6111`; field/local ladders). Functionally correct but heavier, and conflates the covariant-nullability case with the true-downcast case.
- **wt_files:** `src/codegen/values.jl`, `src/builder/instr_builder.jl`, `src/codegen/calls.jl`
- **dart2wasm_ref:** `translator.dart:847-852` (ref_as_non_null vs ref_cast)

### P10 — No uniform dummy-value synthesis for dead arms *(medium, medium)*
WT emits ad-hoc `ref.null`/`i64.const 0`/`emit_phi_type_default` (`stackified.jl:556`) per site; union wrap stuffs null+tag for incompatible arms (`unions.jl:197-206`) — part of the source of validation mismatches.
- **wt_files:** `src/codegen/values.jl`, `src/codegen/stackified.jl`, `src/codegen/unions.jl`
- **dart2wasm_ref:** `globals.dart:instantiateDummyValue` (99-126), called from `translator.dart:convertType` (836-841)

### P11 — Manual numeric br-depth math vs symbolic Labels *(high, medium)*
`get_forward_label_depth/get_loop_label_depth` (`stackified.jl:495/525`, +1 at `:1626/1654`, inner-loop offsets `:507-516`) hand-compute branch depths; `br!(b,depth)` (`instr_builder.jl:217`) only checks depth-in-range, so an off-by-one yields a well-typed wrong branch. dart2wasm `b.br(Label)` (label.depth at `_pushLabel:372`) makes that impossible. InstrBuilder already has a validator label stack to build symbolic labels on.
- **wt_files:** `src/codegen/stackified.jl`, `src/builder/instr_builder.jl`
- **dart2wasm_ref:** `instructions.dart:_pushLabel` (372) + br(Label)

### P12 — All flow generators built strict=false *(medium, medium)*
`flow.jl:6`, `stackified.jl:9/361`, `conditionals.jl` build InstrBuilder with strict=false, so the validator never gates control-flow lowering — the code most prone to stack imbalance (mismatched if/else arms, wrong br depth, phi stores). Opaque `emit_raw!` sub-body splicing defeats validation.
- **wt_files:** `src/codegen/flow.jl`, `src/codegen/stackified.jl`, `src/codegen/conditionals.jl`
- **dart2wasm_ref:** `instructions.dart:_verifyTypes + _reachable` (128/148)

### P13 — No ref.cast soundness check *(high, small)*
`ref_cast!` (`instr_builder.jl:383`) and `validate_gc_instruction!` REF_CAST (`validator.jl:701`) pop-any/push-target with no verification that the target heaptype is a subtype of the input — cannot reject a malformed downcast. The single most common GC-codegen unsoundness; only caught by the external wasm-tools subprocess (silent no-op when absent, `src/WasmTarget.jl:390`).
- **wt_files:** `src/builder/instr_builder.jl`, `src/builder/validator.jl`
- **dart2wasm_ref:** `instructions.dart:ref_cast` (:1155) / `_verifyCast` (:1132)
- **Do:** add the `!target.isSubtypeOf(input)` reject. **Highest soundness-per-effort ratio in the ledger.**

### P14 — No non-defaultable-local-init tracking *(medium, medium)*
`local_get!` (`instr_builder.jl:185`) checks only value type, never initialization state; a get-before-set of a non-nullable ref local produces invalid wasm only wasm-tools catches. WT works around this by making such locals nullable/AnyRef rather than enforcing the rule.
- **wt_files:** `src/builder/instr_builder.jl`, `src/builder/validator.jl`
- **dart2wasm_ref:** `instructions.dart:_initializeLocal` (:175) + local_get (:595)

### P15 — Builder validator at strict=false on all main paths *(medium, medium)*
Every InstrBuilder in compile_value/compile_statement/compile_condition_to_i32 and all of generate.jl/statements.jl is strict=false (`statements.jl:160` et seq ~30 sites; `values.jl:408`; `generate.jl:807+`); it only throws under WT_BUILDER_STRICT (`instr_builder.jl:97`). By default WT records validator errors but never acts; the actual gate is the external wasm-tools. The builder validator is near dead-weight in the default config.
- **wt_files:** `src/builder/instr_builder.jl`, `src/codegen/statements.jl`, `src/codegen/values.jl`, `src/codegen/generate.jl`
- **dart2wasm_ref:** `instructions.dart:InstructionsBuilder` (assert-wrapped _verifyTypes/_checkStackTypes)

### P16 — wasm-tools gate is a silent no-op if absent *(medium, medium)*
`validate_wasm_bytes` (`src/WasmTarget.jl:390-393`) returns bytes unchanged with a one-time warning when wasm-tools is missing. With the builder validator off and ref/cast/local-init checks absent, such environments have effectively NO operand-level gate.
- **wt_files:** `src/WasmTarget.jl`, `src/builder/instr_builder.jl`
- **dart2wasm_ref:** `instructions.dart:InstructionsBuilder` (in-process assert validator, no external dep)

### P17 — Two strict-mode escape hatches re-open the silent-trap hole *(medium, medium)*
(a) `record_unsupported!` downgrades soundness_fatal value-stubs to non-fatal for any function not in TRIM_ENTRY_NAMES (`diagnostics.jl:195-201`) — a buried wrong-value stub in a DISCOVERED callee compiles clean and traps off-sample; (b) `emit_unsupported_stub!` gates fatality on `stmt_must_execute` (`diagnostics.jl:238`). Both are sound only under the dead-in-module assumption the fuzzer checks empirically. WT_PARANOID_STUBS (`diagnostics.jl:147`) closes (a) but is OFF by default.
- **wt_files:** `src/codegen/diagnostics.jl`
- **dart2wasm_ref:** `code_generator.dart:visitAuxiliaryStatement` (:3684, unconditional UnsupportedError)

### P18 — struct/array field type passed by caller, not derived *(high, medium)*
`struct_get!/struct_set!/array_get!` (`instr_builder.jl:344-380`) take a bare `type_idx::Integer` plus a caller-supplied `field_type`/`elem_type`; the validator (`validator.jl:608`) validates only against the supplied info — never cross-checks the field index against the registered struct's field count or actual declared type. A wrong field index or disagreeing field_type is invisible to WT's validator.
- **wt_files:** `src/builder/instr_builder.jl`, `src/builder/validator.jl`
- **dart2wasm_ref:** `instructions.dart:938-1032` (struct_get/struct_set/array_get derive type from the ir.StructType/ir.ArrayType object)
- **Do:** make the registered StructType/ArrayType the single source of truth; derive field/elem type + implicit bounds from it.

### P19 — Dispatch-miss = bare unreachable, no MethodError *(medium, small)*
WT's typeId if-chain ends in a bare `unreachable!` (`calls.jl:1707`) with no diagnostic; an unanticipated runtime type silently traps. The value-returning unresolved path loud-rejects via gated `emit_unsupported_stub!` (`calls.jl:6360`), but the inline fallthrough has no message tying the trap to "no method for typeId X".
- **wt_files:** `src/codegen/calls.jl`
- **dart2wasm_ref:** `dynamic_forwarders.dart:_generateMethodCode` (noSuchMethod on miss) + `code_generator.dart:2094`

### P20 — Dormant hash-dispatch hand-counts br-depths / byte-splices *(medium, medium)*
`dispatch.jl:429,1052,1101` splice via `emit_raw!/emit_typeof!` with manual br-depth arithmetic (`br!(b, UInt32(4))` at `dispatch.jl:554`, `br_done_depth + 1` at `:1241`). Exactly the hand-encoded construction the v0.4.0 migration was meant to eliminate; a latent off-by-one hazard in untested-in-production code.
- **wt_files:** `src/codegen/dispatch.jl`
- **dart2wasm_ref:** `code_generator.dart:_polymorphicSpecialization` (w.Label, b.br(block))

### P21 — No `needsConversion` gate; per-ladder no-op handling *(low, small)*
dart2wasm computes `needsConversion` once (`translator.dart:824`) and convertType emits NOTHING when `from==to`/`from<:to`. WT's ladders each re-derive `from===to`/`wasm_subtype` locally with different short-circuits (`emit_return_coerced!` has its own early branch + `return_type_compatible`, `values.jl:239`; the big arg ladder doesn't uniformly guard the no-op). Risk: redundant ref.cast (perf) or double-emit.
- **wt_files:** `src/codegen/values.jl`, `src/codegen/calls.jl`
- **dart2wasm_ref:** `translator.dart:824` needsConversion + `845` guard
- **Do:** falls out for free once B1 (single convertType) lands.

### P22 — RawBytes escape hatch keeps the IR non-total *(low, medium)*
`InstrIR.RawBytes` (`instr_ir.jl:148`; `emit_raw!`, `instr_builder.jl:496`) is still a live IR member, used pervasively (`stackified.jl`, `values.jl`), carrying opaque bytes with caller-asserted stack effects — defeating IR-level validation for whatever flows through it (e.g. the trunc_sat of F17). dart2wasm has no raw-byte instruction.
- **wt_files:** `src/builder/instr_ir.jl`, `src/builder/instr_builder.jl`, `src/codegen/stackified.jl`
- **dart2wasm_ref:** `instruction.dart:7` (abstract Instruction — no raw-bytes escape hatch); `:18` (MultiByteInstruction is typed const-bytes)

---

## RECOMMENDED LOOP ORDER

The prior hypothesis was **A = union/dynamic boxing first → B = compile_value type-channel + flow dedup → C = strict-default + loud-reject.** The audit **largely CONFIRMS this but REORDERS the early game** because two findings change the cost/benefit: (1) the *same* `wasm_subtype` lattice underlies the boxing soundness (P2), the validator (F6/P3), the concrete-struct nominal blindness (F4), and dispatch signatures (B13) — so the lattice is a shared prerequisite that should be hardened *first*; and (2) a cluster of tiny, high-leverage soundness fixes (P13 ref.cast check, P7 dedicated exn global, F11 Int128 ctz/popcnt) are nearly free and should be banked immediately to shrink the silent-trap surface before the big refactors.

**Loop 0 — Free soundness banking (small, do first).** P13 (ref.cast subtype reject), P7 (dedicated exception global/tag), F11 (Int128 ctz/popcnt branch), F17 (typed trunc_sat → retire one RawBytes use). These are independent, each small, and each closes a real hole or removes a validator-blind splice. Gate every change with the differential fuzzer.

**Loop A — The type lattice (formerly the implicit dependency of everything).** Make `wasm_subtype` (1) nullability-aware (P2), (2) walk `supertype_idx` for concrete types (F4), then (3) wire it into the live validator replacing `wasm_types_assignable` (F6/P3), fixing the NonNullAbstractRef MethodError (B6) en route. This is the keystone: it converts the existing-but-dead lattice into the single relation dart2wasm uses everywhere, and it must precede boxing because boxing soundness (null-into-non-null, classId discrimination) is checked *by* this relation.

**Loop B — Union/dynamic boxing (the biggest real functional gap).** F1 (numeric-only Union → classId-tagged box, the confirmed #1), P1 (one global classId replacing the three disjoint tag schemes), F9/F31 (canonical box, no i31-vs-struct split), P10 (uniform `instantiateDummyValue`). This is where the verdict moves from significant-gap to close, and it depends on Loop A's lattice to validate the boxed flows.

**Loop C — The single convertType funnel + flow/phi dedup.** B1 (collapse 5+ coercion ladders into one `convert_type!`), which automatically delivers P9 (ref.as_non_null), P21 (needsConversion gate), B16 (conditional unbox). Then B2/B10 (collapse flow generators, kill phi byte-inspection) and P11 (symbolic Labels replacing manual br-depths). B5 (single box/unbox funnel) folds in here. This is the largest bloat-retirement and is only safe *after* B because the funnel must encode the new uniform boxing.

**Loop D — Strict-default + total loud-reject.** P5/P6 (eliminate the ~20 silent-trap Cat-C stubs; add named WasmCompileErrors for first-class-closure-value and mutated-capture), P12/P15 (turn on strict builder validation now that the lattice is precise), P17 (close the dependency/must-execute escape hatches), P14 (local-init tracking), P19 (dispatch-miss diagnostic). With a precise validator (Loop A) and a single funnel (Loop C), strict-by-default becomes affordable.

**Loop E — Closures (largest remaining functional delta) + GC nominal hierarchy.** F2/F3/B11 (first-class closure value, capture-by-ref, capture-analysis pass), then B3/P18 (nominal Wasm struct subtype hierarchy + builder-derived field types) and F14/F16 (packed arrays, rec-groups). These are large and best done last, on top of a sound lattice + funnel + validator.

**Deferred / out-of-scope:** F30 (linear memory, by-design out-of-subset), B4 (delete-or-replace the dormant hash dispatch — fold into Loop E if F12/F13 multi-arg/table dispatch is pursued), F8/F22/F23 (deeper lattice completeness), the string i16 rep F7/F18/B8 (large, separate string-parity sub-loop), the EH driver rewrite B7/P4/P8 (depends on the typed-payload tag, a sizeable EH sub-loop seeded by Loop 0's P7).

---

## PER-DIMENSION PARITY VERDICTS

- **Instruction IR completeness:** *close* — broad dart2wasm-shaped 72-struct ADT; only gaps are the saturating-trunc typed structs (spliced via RawBytes) and the by-design-absent linear-memory family; NumOp collapse + RawBytes are debt, not correctness.
- **Type system & subtype lattice:** *close* — the three-hierarchy lattice exists but is nominal-blind (no supertype walk), nullability-blind, structurally incomplete, and not wired into the live validator; the keystone to harden.
- **Value coercion / convertType:** *close* — coerces at all the right boundaries but via 5+ divergent inline ladders instead of one convertType; the central architectural divergence (B1).
- **Boxing & dynamic/Any/Union representation:** *significant-gap* — three disjoint, partly-unsound representations; numeric-only Union collapses to a lossy unboxed primitive (the #1 gap) and there is no uniform classId.
- **Numerics (int widths, float, Int128, BigInt):** *close* — exceeds dart2wasm in surface (8 int widths + Int128 + catchable DivideError); gaps are Int128 div/rem/checked + ctz/popcnt, Float16 mis-typing, and minor trap/fma semantics.
- **Closures & captured variables:** *significant-gap* — closures are monomorphized struct-passing only; no first-class value, no capture-by-ref, no context chain, no capture-analysis pass, and silent-trap rather than loud-reject.
- **Exceptions:** *close* (modern try_table IR) but the model is unsound under nesting — a single module-wide exn global, dropped payloads on the dominant path, catch_all-only with trapping ref.cast, and a ~700-line per-shape driver.
- **Strings:** *significant-gap* — single mutable i8 rep with no class wrapper (root of the SubString/unicode cluster), one-directional JS-string path, and a three-layer hand-written runtime.
- **GC structs/arrays & memory model:** *close* — fully WasmGC, but flat independent structs with a parallel $JlType type-mechanism (no nominal hierarchy), caller-supplied field types (validator-invisible), no packed numeric arrays, no identity hash, depth-capped rec-groups.
- **Control flow lowering:** *close* — a legitimate relooper, but 3+ heuristic generators with copy-pasted phi logic, manual br-depth math (off-by-one = wrong branch), no irreducible-CFG handling/loud-reject, and validator-off (strict=false) on the most imbalance-prone code.
- **Diagnostics, validation & soundness contract:** *close* — strict-by-default loud-reject + external wasm-tools gate exceed dart2wasm by design, but the flagship in-process validator is disabled/permissive, ref.cast/local-init unchecked, loud-reject not yet total (~20 silent-trap stubs + two escape hatches), and the core gate degrades to an optional external binary.
- **Dynamic dispatch & vtables:** *close* — static monomorphization devirtualizes nearly everything (the broad analogue of singularTarget), but the live residual path is single-arg O(n) inline if-chains, a full hash-table subsystem sits dormant/dead, and there is no shared classId+offset table despite WT already computing the DFS ranges.

---

**Executive summary:** WasmTarget is architecturally close to dart2wasm — 8 of 12 dimensions are "close," and several exceed dart2wasm (strict-by-default loud-reject, an external revalidation gate, 8 int widths + Int128). The four "significant-gap" dimensions (boxing, coercion, closures, strings) plus the cross-cutting weaknesses all trace to **two missing dart2wasm keystones: one uniform value representation (classId-tagged boxing) and one coercion funnel (convertType) — both validated by one subtype relation that WT *has* (`wasm_subtype`) but has wired into almost nothing.** The most damaging single defect is F1: numeric-only Unions collapse to a lossy unboxed primitive, making Int 1 and Float 1.0 indistinguishable, with the value-type resolver ignoring WT's own `needs_anyref_boxing` predicate. The bloat dimensions (5+ coercion ladders, 3+ flow generators, the dormant hash-dispatch subsystem, the three-layer string runtime) exist *because* there is no single funnel, so closing the boxing/coercion/lattice trio retires both functional gaps and architectural debt at once.

**The single most important first loop:** harden the subtype lattice — make `wasm_subtype` nullability-aware (P2) and supertype-chain-aware (F4), then wire it into the live operand-stack validator in place of the permissive `wasm_types_assignable` (F6/P3) — banking the near-free P13 ref.cast subtype check alongside it. This is the prerequisite the boxing rework, the convertType funnel, and strict-by-default validation all depend on, and it turns WT's existing-but-dead "Mirrors dart2wasm HeapType.isSubtypeOf" lattice into the single relation dart2wasm uses everywhere.