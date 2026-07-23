# WasmTarget parity: current authority

This is the only authoritative parity roadmap in `dev/`.

It is deliberately short. Historical campaign plans are useful explanations of how the
current architecture was reached, but they are not a backlog. Current implementation reality
and its evidence are read in this order:

1. the current implementation;
2. behavioral and native-vs-Wasm differential tests;
3. `test/parity_ratchet.jl` and `dev/parity_baseline.toml`;
4. `dev/CERTIFICATION.md`, which is a dated source-to-source audit;
5. this roadmap.

If prose conflicts with the implementation, the prose is stale. If a lock conflicts with
behavior, the lock is incomplete. Never turn an old claim into work without reproducing it.

## Audit stamp

- Audit date: **2026-07-22**
- WasmTarget revision: **`3a93ae24`**
- dart2wasm oracle: dart-lang/sdk **`898a1e4bbfbc472dc0a9505dc7d2e4c21d6f856e`**
- Ratchet: `julia --project=. test/parity_ratchet.jl` **passes**
- CI for that exact revision: **green** ([run 29357985108](https://github.com/GroupTherapyOrg/WasmTarget.jl/actions/runs/29357985108))

dart2wasm is a structural design oracle, not a feature checklist. Julia and Dart have different
language semantics. A dart2wasm-shaped implementation is accepted only when native Julia is the
behavioral oracle and unsupported Julia remains correct-or-loud.

## Current architecture

The following are implemented and machine-locked. They are not remaining roadmap items.

| Area | Current WasmTarget state | Principal locks/evidence |
|---|---|---|
| Instruction emission | The live production path is builder-native typed instruction IR; no raw `emit_raw!` bridge reaches it | L6, L12, L13, L16, L27, L65 |
| Control flow | One stackifier, symbolic labels, normalized crossing regions, explicit rejection outside the supported shape | L3, L67, L87, L89, L90 |
| Value conversion | One expected-type channel and one conversion/boxing funnel; no post-emission type guessing or value repair | L1, L2, L4, L5, L18, L35, L84 |
| Correct-or-loud | Known unsupported exits in the certified model are diagnostic-routed; ratchets forbid the classified silent traps, fabricated repairs, post-build repair, and swallowed failures | L8, L14, L19, L38, L39, L56-L66, L70-L77, L94 |
| Closed world | One unconditional reachability fixpoint for roots, invokes, dependencies, callables, and selectors | L17, L26, L40, L78, L80, L91, L93 |
| Object model | Classed WasmGC objects with canonical Top/Object prefixes, class IDs, identity hash, exact type objects, and recursion groups | L20, L23, L28, L29, L43-L46, L68, L95 |
| Closures | One closure object/context/vtable/function-type representation for capturing closures and static tear-offs; dynamic calls use `call_ref` | L23, L24 and closure execution tests |
| Dynamic dispatch | Monomorphic direct calls plus one classId/selector-offset table; FNV/hash dispatch is deleted | L10, L36, L49, L50 and `test/m8_selector_table.jl` |
| Exceptions | Exact Julia exception objects and payloads flow through the typed exception tag; bottom bodies retain their real throwing flow | L56-L60, L67, L81, L82, L92 |
| Constants and globals | Exact physical representations and concrete runtime classes; declarative framework roots; one module start | L37, L44, L48, L55, L66, L88, L91 |

The detailed correspondence to dart2wasm lives in `dev/CERTIFICATION.md`.

## Honest current boundaries

These are coverage boundaries, not evidence that the architecture above is absent.

### Closed-world dispatch

- Eligible exact and monomorphic calls in the collected closed world devirtualize.
- Routable class-based selector sets support one varying axis, or two through a cascade when
  the second-axis class ID uniquely resolves each tied first-axis group.
- Three-or-more varying axes and genuinely open-world method discovery are not selector-routable
  today and must reject loudly.
- Reflection, `eval`, world-age mutation, and runtime method definition are not part of a frozen
  browser module.

### Native and host capabilities

- A curated set of foreign calls has deliberate lowerings or pure-Julia overlays.
- Arbitrary `ccall`, `dlopen`, `Ptr`-based libraries, BLAS/LAPACK/SuiteSparse solver binaries,
  filesystem, sockets, host entropy/time, threads, tasks, and atomics do not become browser-safe
  because their Julia call sites are visible.
- These need an explicit host import, a pure-Julia implementation, or a separately built
  linear-memory Wasm sidecar. Recognized unsupported reachable calls are routed to loud
  failures; an unclassified lowering is a bug to reproduce and lock.

### Language and runtime surface

- The differential catalogue proves its tested signatures and compositions, not all Julia.
- Package support must be established with end-to-end canaries using ordinary package APIs.
- Code size, compile latency, browser feature availability, and target-specific numerical behavior
  are production concerns even when a function is semantically supported.

## Current roadmap

Roadmap entries require a reproducer, a capability boundary, or a measured maintenance problem.

1. **Package capability canaries.** Exercise MOI/JuMP modeling, SciMLBase problem construction,
   explicitly pure-Julia OrdinaryDiffEqTsit5 scalar/generic-state paths, and negative controls.
   Record the first reachable unsupported edge and its source provenance.
2. **Capability manifest and diagnostics.** Classify required Wasm features, host imports,
   foreign/native calls, and unsupported dynamic semantics. Surface the call chain rather than a
   generic compilation failure.
3. **Native sidecar prototype.** For libraries that cannot be represented as WasmGC Julia, test a
   curated core-Wasm module with linear memory, a narrow generated ABI, and explicit ownership.
   Do not imply that existing host JLL artifacts can be loaded by a browser.
4. **Frontend isolation.** Stop allowing target codegen to depend pervasively on raw `CodeInfo`
   shapes. Introduce a normalized frontend boundary while preserving the current path.
5. **UnifiedIR experiment, not migration.** Once Julia exposes a usable nightly API with method
   table overlays, shadow-compile a bounded corpus through UnifiedIR and the existing frontend.
   Compare semantics and diagnostics before deleting the current stackifier or capture analysis.
6. **Continuous differential expansion.** Add failures found by real packages to the native-vs-Wasm
   corpus and lock every fixed soundness class. This is permanent verification, not a one-time
   parity milestone.

## UnifiedIR watch

JuliaLang/julia#62334 is strategically aligned with WasmTarget: structured regions, explicit
cells/closures, extensible columns, typed queries, and provenance could simplify the compiler
frontend substantially. As audited, it is still a draft RFC against Julia `master`, is not enabled
for bootstrap, retains `CodeInfo` as a boundary for now, and does not replace codegen.

UnifiedIR does **not** replace the builder-native Wasm backend, WasmGC representation, runtime
overlays, selector table, browser bridge, or native/JLL boundary. Do not make production depend on
the RFC or duplicate upstream work while its API is fluid.

## Updating this document

Every proposed gap must include:

- a current reproducer or source census;
- whether failure is wrong result, invalid module, loud rejection, or missing capability;
- native Julia as the semantic oracle;
- the relevant structural lock or a new lock preventing recurrence;
- the exact dart SDK revision when dart2wasm is cited;
- a clear distinction between supported-model completion and broader feature coverage.

Do not use percentages such as “production parity” without a declared denominator. Do not infer
current work from the historical march, loop, migration, or cleanup documents.

## Historical record

Completed campaigns are summarized once in [`HISTORY.md`](HISTORY.md). The detailed old
plans and ledgers were removed so stale action lists cannot compete with this roadmap.
Git history is the source for reconstructing their exact original context.
