# dart2wasm Structural-Parity Certification — WasmTarget.jl
**Branch `wt-dart2wasm-parity` · certified 2026-07-02 · the M7 closing document of
`dev/PARITY_MASTER.md`. Every claim below carries file:line on BOTH sides; every "LOCKED"
row is machine-enforced by `test/parity_ratchet.jl` + `dev/parity_baseline.toml` at every
commit and inside `Pkg.test` shard 0.**

## The five load-bearing invariants

| Invariant | dart2wasm evidence | WasmTarget evidence | Status |
|---|---|---|---|
| **I1 — Validating builder**: the instruction builder is a type-checking abstract interpreter; every emit subtype-checks its stack effect and throws at the emit site | `wasm_builder/src/builder/instructions.dart:98-294` (`_checkStackTypes` :252, 233 assert-gated verify sites) | `src/builder/validator.jl` (735L live model) + `instr_builder.jl`: **strict is the DEFAULT** (`_wt_builder_strict`), zero per-builder opt-outs (**LOCK L6**), `mod` threaded into ~330 builders so the FULL `wasm_subtype` lattice gates every push/pop; `local_set!` validates against the local's type. **Beyond dart: always-on (dart's checks vanish in release builds)** | ✅ **DELIVERED + LOCKED** |
| **I2 — Typed expression channel**: a value's type is a byproduct of emission through ONE `wrap(node, expected)` chokepoint; never re-derived | `code_generator.dart:39` (`ExpressionVisitor1<w.ValueType,w.ValueType>`), `:879-888` (`wrap`) | `emit_value!(b, val, ctx, expected)` (values.jl) = emit → actual type off the validator stack (`compile_value_typed`) → `convert_type!` → expected; `_seed_builder_locals!` makes `local.get` types truthful; **`infer_value_wasm_type` DELETED** — the ~10 legit pre-emit deciders renamed `static_wasm_type` under a pre-emit-ONLY contract (**LOCK L4**); every remaining untyped splice carries the god-fn-seam annotation (**LOCK L9**) | ✅ **DELIVERED + LOCKED** (seam-typing rides the god-fn decomposition, ratchet R2) |
| **I3 — One coercion funnel**: ALL boundary adjustment through one `convertType`; boxing exists only there | `translator.dart:828-875` (identity/drop/non-null/cast/box/unbox arms + loud throw) | `convert_type!` (values.jl:383+) with the same arms incl. numeric widening; ONE box producer `emit_classid_box!` / ONE unbox consumer `emit_classid_unbox!` / ONE numeric discriminator `emit_isa_classid!` (**LOCK L1**); returns (`emit_return_coerced!`), phi stores (`emit_phi_local_set!` 366→36, both stackified clusters), field/arg stores all wrap through it; **no i31 anywhere** (**LOCK L2**) | ✅ **DELIVERED + LOCKED** (remaining raw coercion ops = intrinsic implementations, ratchet R7 → the dart-style intrinsics table) |
| **I4 — One type translator + DFS classIds**: single type map; DFS pre-order ids; field 0 = classId; is-tests = dense-range check | `translator.dart:493/516/614`, `class_info.dart:27/369/642-686`, `dynamic_forwarders.dart:250-259` | ONE resolver (`_resolve_multivariant_union` + `get_concrete_wasm_type`); DFS `ensure_type_id!` + `$JlBase` classId@0; **zero placeholder (typeId=0) headers** — boxes, dispatch results, Int128/UInt128, size tuples, Vector/NamedTuple/Expr headers all carry real ids; abstract isa = `emit_classid_range_check!` (the exact 3-instruction `i32.sub; i32.le_u` unsigned window); **the tagged-union wrapper family is DELETED** (**LOCK L5**) — a Union value is JUST an AnyRef discriminated by classId | ✅ **DELIVERED + LOCKED** (strings classId = certified gap, below) |
| **I5 — Loud failure posture**: unmodeled input throws; no guess-and-continue; dummies only in provably-dead positions | `translator.dart:614/502/872`, `code_generator.dart:145-153` (`unimplemented` = diagnostic + validating trap), `globals.dart:99` | `record_unsupported!` router (entry-strict policy); **every `unreachable!` is diagnostic-routed or an annotated structural trap — zero silent stubs** (**LOCK L8**); the 2 surviving type-safe defaults are diagnosed; **the #1 silent miscompile (`sum(x for x in xs if c)` → 0) is FIXED and locked into smoke** (3 variants) | ✅ **DELIVERED + LOCKED** |

## Supporting dimensions

| Dimension | dart | WT | Status |
|---|---|---|---|
| One dynamic-value box `{classId@0, value@1}` | `translator.dart:202/855-870`, `class_info.dart:27-28/84-86` | `emit_classid_box!`/`emit_classid_unbox!` — real classIds, `emit_box_type_id!` demoted to internal fallback (0 external callers, L1) | ✅ |
| One control-flow lowering | one `CodeGenerator`, no strategy choice | `generate_structured` = try/catch \| single-block \| **the stackifier**; ALL 8 legacy strategies deleted (−4,850 lines; a documented multivar-phi miscompiler among them) (**LOCK L3**) | ✅ |
| External validator | dart ships none — the builder is the gate | `wasm-tools` demoted to opt-in (`validate=true` / `WT_VALIDATE=1`, CI cross-check) (**LOCK L7**); certified by a full corpus run with validation OFF | ✅ |
| Typed captures (`Capture.type`) | `closures.dart:1030/1112-1118`, `translateTypeOfLocalVariable` | `f3_self_box_joins` (closure-local optimistic-verify contents solver) + the numeric-join local typing: the mutable-capture closure body compiles **valid** wasm | 🟡 partial (see gaps) |

## Certified remaining gaps (the post-PR completion campaign — tracked, never hidden)

1. **Shared-Context semantics (M6)**: the parent scalar-replaces an ESCAPING `Core.Box` while
   the closure mutates the real one — two copies. Fix = dart `Context` structs
   (`closures.dart:970-1013`): ONE materialized cell, no scalar replacement across an escaping
   closure. Documented xfails: `F3_mutable_capture/{mutate_capture, mutate_capture_typed}`.
2. **Dispatch table (M6)**: dart's ONE flat funcref table `table[classId + selector.offset]`
   with offset packing + monomorphic direct-call (`dispatch_table.dart:391-444`,
   `code_generator.dart:2072-2125`) vs WT's FNV-hash tier-2 scheme. Design fully mapped.
3. **Strings classId (M6)**: strings are bare `array<i32>` refs without the `$JlBase` header,
   so classed checks can't see them (`isa AbstractString` over `Any[]` — documented xfail
   `strings_lack_classid`). Fix = class the string rep (dart: String is a class).
4. **God-fn decomposition (M4 tail)**: `compile_call`/`compile_invoke`/`compile_new` are
   bytes-returning; their internal splices are the annotated seams (L9) and the `emit_raw!`
   ratchet R2 (~244); the dart-style typed intrinsics table (`intrinsics.dart:28-71`) lands
   with it, locking R7.
5. **`infer_value_type` consolidation**: reclassified as dart's `node.getStaticType` analog
   (a static JULIA-type query); consolidate + contract-document with the M4 tail.

## The enforcement (what makes this durable)

**NINE LOCKS** (exact-match, every commit + CI): L1 one-box-producer · L2 no-i31 ·
L3 one-lowering · L4 no-post-emit-re-guess · L5 no-tagged-union · L6 all-builders-strict ·
L7 wasm-tools-demoted · L8 no-silent-traps · L9 no-unjustified-untyped-emission.
**RATCHETS** (may only decrease): R2 emit_raw seams · R3 static-type-query callers ·
R5 pre-emit julia-type queries · R7 raw coercion ops · R11 patch-tag sediment.

## Soundness certification

Every phase closed with its own full capped gate (`WT_TEST_CONCURRENCY=2 Pkg.test`): 10
process shards (~2,690 tests incl. Aqua + all regression backfills + the Snapshot-islands
integration) + 9 differential fuzz suites (293 property tests over LinearAlgebra/Dates/
Random/Statistics/SparseArrays/ForwardDiff/StaticArrays/SimpleDiffEq). The M7 closing matrix
ran the full corpus twice: once with external validation OFF (the builder is the gate) and
once with `WT_VALIDATE=1` (wasm-tools independently re-verifying every module). En route the
campaign found and fixed **seven real silent-wrong bugs** the old structure was hiding, the
flagship being the filtered-generator fold returning 0.
