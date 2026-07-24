# JuMP → WasmGC certification plan

Status: active engineering plan. The machine-readable claim surface lives in
`test/integration/jump/capabilities.toml`; it takes precedence over prose when
implementation evidence changes.

## What “full JuMP” means

“Full JuMP” is not one compiler switch. It is a versioned capability profile
whose supported and unsupported boundaries are executable. A feature is
supported only after native Julia, raw Wasm, `-Os`, `-O3`, browser, and artifact
gates agree. Unsupported paths must reject clearly; hangs, silent stubs,
unexpected Snapshot fallback, and plausible-but-wrong solver results are
failures.

The first useful public finish line is deliberately narrower than the entire
ecosystem:

- ordinary JuMP linear-model syntax;
- an audited set of MOI bridges;
- a real pure-Julia browser solver;
- correct termination status, objective, primal, and dual results;
- reactive re-solve in a Snapshot notebook in Chromium and Firefox;
- explicit diagnostics for every unsupported feature.

Native solver libraries are a separate sidecar capability. They are never
described as core-Wasm support merely because JuMP can call them on a desktop.

## Evidence required at every stage

Each tier adds all of the following before promotion:

1. a pinned environment and source provenance;
2. deterministic native-vs-Wasm canaries for raw, size, and speed builds;
3. correct-or-loud negative tests and a hard child-process watchdog;
4. bounded generated/property cases, with durable minimized failures;
5. byte-size and compile/runtime budgets that ratchet after a green baseline;
6. a real Snapshot export with zero unexpected fallback;
7. interaction tests in Chromium and Firefox for directory and single-file
   exports;
8. an adversarial review of semantics, downstream impact, and claim wording;
9. a dart2wasm comparison documenting which production mechanism is reused,
   adapted, or deliberately inapplicable.

## Incremental tiers

| Tier | Capability | Principal compiler pressure |
| --- | --- | --- |
| T0 | MOI values and prerequisite collections | concrete layouts, mutation, iteration |
| T1 | `MOI.Utilities.Model` | closed-world type graph and type-ID assignment |
| T2 | caching, copying, attributes, and results | abstract containers and lifecycle |
| T3 | normal JuMP modeling syntax | multi-axis Julia dispatch |
| T4 | `MOI.Utilities.MockOptimizer` | optimizer protocol and result integrity |
| T5 | selected bridges | subtype tests, closures, dynamic dispatch |
| T6 | a tiny deterministic pure-Julia solver | first real solve end-to-end |
| T7 | Tulip profile | sparse factorization, ordering, clocks, BLAS boundaries |
| T8 | constrained Clarabel profile | cones and pure-Wasm QDLDL path |
| T9 | nonlinear expression/evaluator/AD slices | staged nonlinear semantics |
| T10 | callbacks | backend-specific reentrancy and lifecycle |
| T11 | HiGHS/Ipopt sidecars | explicit host ABI, not fake in-module portability |

Ecosystem expansion follows these tiers; it does not redefine them after the
fact. SciML is intentionally later than the first real JuMP solver milestone.

## dart2wasm parity rubric

The comparison is mechanism-by-mechanism, not a claim that Julia and Dart share
the same language semantics.

Reuse or adapt:

- closed-world reachability and concrete subtype metadata;
- deterministic dispatch metadata;
- explicit runtime and collection lowering;
- optimized/unoptimized differential tests;
- stable, validated module construction.

Do not copy:

- Dart's single-receiver object dispatch as a replacement for Julia multiple
  dispatch;
- Dart reified-generic, async, or finalizer machinery where JuMP does not need
  it;
- the assumption that an FFI declaration makes a native JLL portable to Wasm.

Julia UnifiedIR is tracked as a future substrate opportunity, not a dependency
of this plan. The current draft is experimental and cannot be used to waive
today's correctness, dispatch, or closed-world gates.

## Working policy

- The user's normal checkout stays on its existing branch.
- All implementation occurs in an isolated worktree and feature branch.
- A certified tier must leave behind a runnable Snapshot notebook.
- Notebooks remain compiler fixtures until the final audit explicitly approves
  promotion to Snapshot's featured gallery.
- The final deliverable is a merge-ready pull request; it is not merged by this
  work.
