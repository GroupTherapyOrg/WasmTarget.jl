# JuMP → WasmGC certification plan

Status: active engineering plan. The machine-readable claim surface lives in
`test/integration/jump/capabilities.toml`; it takes precedence over prose when
implementation evidence changes.

## Plan authority and revision

The opening adversarial intent audit is a design gate, not a review of a
preselected implementation sequence. It may reorder, split, combine, add, or
remove intermediate tiers when JuMP/MOI architecture, solver boundaries,
WasmTarget evidence, or the dart2wasm mechanism audit shows that a different
dependency order is safer or produces a more useful independently certified
milestone.

The same authority applies at every later adversarial promotion gate. A green
tier may expose a false assumption in a later tier; a failed tier may require a
new prerequisite tier instead of a local workaround. Such changes must update
this plan and `capabilities.toml` before implementation continues. They may not:

- weaken the fixed end-state or redefine a failure as support;
- erase an observed blocker or downgrade a required negative test;
- fold native solver sidecars into the core-Wasm claim;
- skip native/raw/optimized/browser/portable evidence; or
- substitute prose confidence for an executable capability.

The tier table below is therefore the current dependency hypothesis. It becomes
a sequence of commitments only as each promotion gate confirms the next tier.

## What “full JuMP” means

“Full JuMP” is not a boolean claim or one compiler switch. It means the union of
versioned, named capability profiles whose exact operations are executable. A
profile enumerates its JuMP/MOI operations, function/set pairs, attributes,
mutation and optimizer lifecycle, bridges, solver, numeric contract, execution
class, and exclusions. The machine-readable matrix is the denominator; prose
examples cannot expand it.

The first useful public profile is `browser_lp_v1`, deliberately narrower than
the entire ecosystem:

- ordinary JuMP linear-model syntax;
- an explicit matrix of supported affine function/set pairs and operations;
- an audited, enumerated set of MOI bridges;
- a real pure-Julia browser solver;
- correct termination status, objective, primal, and dual results;
- reactive re-solve in a Snapshot notebook in Chromium and Firefox;
- explicit diagnostics for every unsupported feature.

Every solve reports one of three execution classes:

1. `wasmgc`: pure Julia executing inside the WasmGC module;
2. `core_wasm_sidecar`: a separately built linear-memory Wasm module with an
   explicit ABI, ownership, copying, and disposal contract;
3. `remote_host`: a host or network solver service.

Native desktop JLL availability proves none of these classes. HiGHS, Ipopt, and
similar native libraries are never described as core-Wasm support merely
because JuMP can call them on a desktop.

## Correct-or-loud failure contract

Failures are machine-readable and phase-labelled. At minimum the taxonomy
distinguishes:

- unsupported compiler/runtime capability;
- missing browser capability;
- sidecar load or ABI failure;
- `MOI.UnsupportedAttribute` and `MOI.UnsupportedConstraint`;
- compiler phases `collect`, `type_graph`, `dispatch`, `emit`, and `validate`;
- browser phases `instantiate`, `transport`, and `result_decode`;
- MOI phases `protocol`, `solve`, and `result_query`; and
- legitimate solver outcomes such as `INFEASIBLE` or `DUAL_INFEASIBLE`.

A failure must not leave a partially mutated model, expose stale results, or
silently reuse a previous solve. A generic exception, Snapshot fallback, hang,
or plausible-but-wrong result does not satisfy this contract.

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

Every retained module is byte-hashed, independently validated, and executed
against its native oracle. Cross-platform promotion compares the complete
semantic input/result ledger, not raw module identity: Julia may emit
platform-specific type metadata and identity hashes while preserving the same
validated behavior. Same-platform and cross-platform reproducible builds are a
separate visible compiler property. They may be promoted only by their own
fresh-process and multi-platform gates and are never inferred from behavioral
parity.

Solver stages add an independent mathematical oracle. Native-vs-Wasm agreement
is necessary but cannot certify a solver against itself. Evidence includes
known optima, primal and dual feasibility residuals, objective consistency,
complementarity/KKT checks where applicable, status invariants, and metamorphic
models using scaling, redundant constraints, and variable permutations.
Numerical profiles declare absolute/relative tolerances plus NaN, infinity, and
signed-zero policy; exact-value stages continue to require exact equality.

Resource evidence is cross-cutting: repeated build/solve/reset cycles must show
bounded memory, module, and object growth. Browser stages additionally certify
transport encoding, result decoding, repeated-interaction disposal,
cancellation, and timeouts.

## Current milestone dependency hypothesis

The existing T0 fixture is retained as early evidence but maps into the new
foundation rather than freezing the old tier order. It is named **MOI
value/runtime prerequisites**: it does not import or execute JuMP and therefore
is not evidence that a `JuMP.Model`, JuMP macro, optimizer, or solver works.
Its maximum safe claim is that the listed MOI scalar operations and one
`OrderedDict` prerequisite execute with the recorded native/Wasm parity.

```text
F0  Certification substrate
    pins/provenance, phase telemetry, watchdogs, failure taxonomy,
    raw/-Os/-O3, browser engines, claim manifest
 |
F1  MOI-derived Julia runtime shapes
    exact concrete layouts, collections, closure topologies, exceptions,
    dispatch limits, and repeated-allocation stress extracted from the pinned
    MOI storage call graph but certified in isolating canaries
 |
F2  MOI algebra vocabulary
    indices, declared Function/Set pairs, exact value semantics
 |
F3a VariablesContainer
    first actual MOI storage gate: vector-backed variable/bound storage,
    add/list/delete/validity, mask transitions, and duplicate-bound errors
 |
F3b Objective + constraint stores
    actual ObjectiveContainer and the minimal affine StructOfConstraints /
    VectorOfConstraints slice; real CleverDict lifecycle enters here
 |
F3c Narrow MOI.Utilities.GenericModel
    compose only the independently certified stores; name maps, ext dictionary,
    list/query/delete/empty/copy within the declared profile
 |
F3d Full default MOI.Utilities.Model pressure gate
    instantiate the generated all-function/all-set default model only after the
    narrow aggregate works; this is a breadth/pressure gate, not a prerequisite
 |
F4  Expanded storage, index maps, attributes, copy/cache, invalidation
    DoubleDict and each additional function/set family independently certified
 |
F5  MockOptimizer state machine
    optimize, statuses, result counts, primal/dual/objective queries,
    modify/reset/re-optimize, correct unsupported responses
 |\
 | F6a JuMP frontend construction
 |     @variable/@constraint/@objective into the certified backend
 |
F6b Browser transport and ownership
    input/result encoding, repeated interaction, disposal, cancellation,
    timeout, memory/module bounds
 |\
F7  Tiny direct-form pure-Julia solver
    no bridges initially; independent mathematical and metamorphic oracle
 |
F8  Selected bridge profiles
    source-to-target transforms certified end-to-end against F7 results
 |
F9  browser_lp_v1
    named JuMP LP subset, reactive rebuild/re-solve, executable matrix
 |
F10 Pure-Julia production-solver track
    SparseMatrixCSC prerequisite -> Tulip profile ->
    selected Clarabel cones and pure-Wasm QDLDL
```

The first JuMP frontend browser promotion must exercise a workflow rather than
a scalar output: construct a `JuMP.Model`; add variables, constraints, and an
objective; mutate a bound, coefficient, and right-hand side; query counts and
expressions; render or serialize the model; perform at least two sequential UI
updates; reload; and repeat without stale or duplicated state. Solver profiles
add infeasible, unbounded, and expected-error cases alongside successful
models. Every claimed cell must be a full authoritative island; Snapshot
fallback is a hard failure.

Parallel capability tracks begin only after their stated prerequisites:

```text
After F0/F6b:
S0 sidecar ABI, ownership, disposal, and security contract
 -> S1 tiny deterministic core-Wasm sidecar fixture
 -> S2 curated HiGHS/Ipopt builds labelled core_wasm_sidecar

After F5/F6a:
N0 nonlinear expression representation
 -> AD/evaluator slices -> named nonlinear solver profiles

C0 backend-specific callback/reentrancy profiles
   optional and never implied by browser_lp_v1
```

SciML remains later than the first real JuMP solver milestone. It does not
expand any JuMP profile merely by sharing compiler mechanisms.

### F1–F3 diagnostic boundary

F1 is intentionally neither a toy-runtime suite nor a claim that MOI storage
works. Its cases must cite the pinned MOI source file, line, downstream type,
and operation that require each shape. They then isolate those exact shapes so
that a failure identifies a compiler/runtime mechanism rather than the entire
MOI storage stack. The required initial surface is:

- nested concrete mutable and immutable layouts plus
  `Union{Nothing,T}` field mutation;
- `Vector` growth, deletion, iteration, copy, and retained-reference behavior;
- the exact downstream dictionary key/value shapes, including MOI indices,
  strings, symbols, tuple/type keys, and nested dictionaries;
- actual `OrderedDict` lifecycle and ordering semantics;
- singleton function fields matching the pinned `CleverDict` defaults, plus
  separately source-derived ephemeral captured-closure patterns;
- `KeyError`/`ErrorException`, bounded one- and two-axis closed-world exception
  dispatch, and sustained same-instance allocation pressure.

The allocation corpus may establish bounded behavior for the named workload; it
must not be worded as general garbage-collector support.

`try`/`rethrow` first enter the pinned authoritative path in
`CachingOptimizer`; `finally` first enters in later bridge behavior. They are
therefore F4-or-later obligations, not invented F1 storage prerequisites.
Typed duplicate-bound exceptions belong to the real `VariablesContainer`
lifecycle in F3a.

Actual `VariablesContainer`, `VectorOfConstraints`/`CleverDict`, and
`MOI.Utilities.Model` may run under short watchdogs during F1 as discovery
probes. A probe failure records the earliest phase and blocker; a surprising
probe success does not move the claim into F1 or replace the tier's independent
evidence. F2 then proves the real MOI method bodies and algebra needed by
storage. F3a is the first authoritative actual-storage claim and covers the
current pinned `VariablesContainer`, whose representation is three vectors
(`Vector{UInt16}` plus lower/upper coefficient vectors)—not `CleverDict`. F3b
adds the objective and constraint stores; `CleverDict` first enters the
authoritative path through `VectorOfConstraints`. F3c claims only a narrow
`GenericModel` composed from independently certified stores. F3d then exercises
the generated all-function/all-set default `MOI.Utilities.Model` as a separate
breadth and pressure gate. The full default model is never a prerequisite that
can obscure smaller independently useful wins.

## dart2wasm parity rubric

The comparison is mechanism-by-mechanism, not a claim that Julia and Dart share
the same language semantics.

Each milestone records a pinned dart2wasm revision and exact source paths in a
three-column decision record: reused mechanism, Julia-specific adaptation, and
explicitly inapplicable. Native Julia semantics and correct-or-loud behavioral
evidence remain authoritative; dart2wasm is a structural oracle only where the
runtime problem is genuinely shared.

Reuse or adapt where applicable:

- closed-world reachability and concrete subtype metadata;
- allocation/type discovery and recursive concrete layouts;
- deterministic dispatch metadata;
- explicit runtime collection lowering as an architectural example;
- equality, hash, and identity handling;
- closure contexts, exception transport, and module initialization;
- selector metadata where it maps to a Julia dispatch problem;
- optimized/unoptimized differential tests;
- stable, validated module construction.

Do not copy:

- Dart's single-receiver object dispatch as a replacement for Julia multiple
  dispatch;
- Dart reified-generic, async, or finalizer machinery where JuMP does not need
  it;
- the assumption that an FFI declaration makes a native JLL portable to Wasm.

Dart `Map` is not evidence that Julia `Dict` or `OrderedDict` works. Dart
single-receiver dispatch is not evidence for Julia multi-axis dispatch. MOI
lifecycle, sparse algebra, solver mathematics, and sidecar ABI correctness have
no meaningful dart2wasm parity requirement beyond shared module-construction
and validation discipline.

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
