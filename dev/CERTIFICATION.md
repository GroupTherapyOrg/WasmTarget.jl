# WasmTarget.jl ↔ dart2wasm structural certification

Status: **GREEN — strict builder/codegen parity within the declared scope**

> **Bounded revalidation (2026-07-22).** Builder emission, closure/vtable layout,
> selector dispatch, and current locks were rechecked against WasmTarget `3a93ae24` and
> a pinned upstream dart-lang/sdk checkout at
> `898a1e4bbfbc472dc0a9505dc7d2e4c21d6f856e`. The parity ratchet passes and CI for that
> exact WasmTarget revision is green
> ([run 29357985108](https://github.com/GroupTherapyOrg/WasmTarget.jl/actions/runs/29357985108)).
> This is a validation delta, not a relabelled full certification run.

Original full source/full-suite audit date: 2026-07-11

Original WasmTarget implementation commit audited: `e6114f8d4d5156ddbe8df762d6494758bdb36307`

Original Dart architectural oracle: dart-lang/sdk `upstream/main` at
`594947b79dc1af3df7e80546ad2e6a37dec7a727`

The table below is the original fresh source audit of the original revisions above. It
does not inherit claims from an older certificate. At those revisions a green row required
all three of: source correspondence, a machine-enforced parity lock, and executable evidence.

## Certified scope

The typed Wasm builder, closed-world planner, runtime representation, structured control
flow, conversion/boxing channel, dispatch table, constant construction, exception flow,
and production code-generation route are in scope.

Async, FFI, threads, deferred loading, and JS glue remain explicitly out of scope. An
exclusion never permits fake compilation: a reachable unsupported construct must reject
with a diagnostic. No silent fallback, fabricated value, validator opt-out, or post-build
repair is certified or permitted.

## Fresh source-to-source audit

| Invariant | Audited dart2wasm oracle | Audited WasmTarget implementation | Machine evidence | Result |
|---|---|---|---|---|
| Typed instruction builder | `pkg/wasm_builder/lib/src/builder/instructions.dart`: `InstructionsBuilder`, `_verifyTypes`, `_stackTypes` | `src/builder/instr_builder.jl` and `validator.jl`: live production emission updates and checks the operand stack | L6, L13, module-builder tests | ✅ |
| Symbolic control labels | dart `Label`, `Block`, `Loop`, `_labelIndex`; branch APIs accept `Label` | `ControlLabel` identity is returned by block/loop/if/try-table; codegen retains it; `_label_depth` exists only at serialization | L87; stale/numeric-label rejection and catch-target tests | ✅ |
| Definite local/control validation | dart tracks label base heights, reachability, target types, and local initialization | validator tracks entry height, input/output types, reachability, branch/catch arity and subtyping; partial primitive initialization requires CFG must-proof | L6, L74, L79, L87 | ✅ |
| Typed expression channel | dart wraps expressions against an expected representation and retains produced types | `emit_value!` uses the builder-tracked produced type and the sink's physical expected type | L4, L9, L18, L35; R17=29 | ✅ |
| One conversion and boxing funnel | dart `translator.dart` `convertType` owns casts, null checks, boxing, and unboxing using the exact Dart class | `convert_type!`, `coerce_stack_top!`, and sole `emit_classid_box!`; numeric boxing requires a concrete Julia source class | L1, L2, L5, L84; R16=0 | ✅ |
| No fabricated values | dart rejects unimplemented conversions instead of substituting an unrelated valid value | constructor, phi, call, invoke, return, exception, constant, string, and allocation paths preserve exact values or reject | L14–L19, L37–L39, L56–L66, L71–L86, L88 | ✅ |
| One production compilation route | dart uses one translator/module strategy and one code-generator family | public APIs enter `compile_module` → `_compile_module_trim` → `_compile_closed_world_plan` → `generate_body` | L17; legacy compilers and mode routers absent | ✅ |
| One structured-flow lowering | dart emits structured Wasm through one code generator and symbolic labels | `generate_body` → `generate_structured` → the sole stackifier; legacy flow families deleted | L3, L67, L87 | ✅ |
| Closed-world fixpoint | dart completes class/member discovery before final layout and dispatch | callable, invoke, dependency, and selector discovery iterate to a real fixpoint without cliffs, round caps, or opt-outs | L26, L40, L75–L80 | ✅ |
| Runtime class layout | dart `class_info.dart`: Top owns classId; Object adds mutable identityHash; class ranges support tests | distinct Top/Object layouts, exact class IDs, ordinary Object inheritance, mutable identity hash, exact range checks | L20, L28, L43–L46, L50 | ✅ |
| Recursive type groups | wasm_builder defines ordered contiguous recursion groups | dependencies/supertypes precede reserved recursive definitions; serializer rejects invalid groups | L29 and recursive-layout execution tests | ✅ |
| Selector dispatch table | dart `dispatch_table.dart`: selector-scoped signatures/rows, classId + offset, indirect call | one selector table with per-slot LUB signatures and classId offsets; FNV dispatch family deleted | L10, L18, L34, L36, L49–L50; R18=0 | ✅ |
| Constants | dart `constants.dart`: one deduplicating constant map with eager/lazy initialization | one constant-global funnel plus exact string/type registries; every known field uses its physical sink and concrete runtime Julia class | L37, L44, L48, L55, L66, L88; R14/R15 | ✅ |
| Exceptions and bottom flow | dart typed exception tag carries exception/stack trace; bottom paths remain unreachable | exact Julia exception objects and payloads travel through the typed tag; bottom bodies compile their real throwing flow | L56–L60, L67, L76, L81–L82 | ✅ |
| Module strategy | dart module strategies are explicit | one monolithic closed-world module | Deferred loading excluded | ✅ |
| No validator repair loop | dart relies on its builder rather than repairing binaries | strict builder validity is unconditional; Binaryen is optimization only; wasm-tools is an optional independent cross-check | L6, L7, L14, L22, L27 | ✅ |

## Machine-enforced locks

`test/parity_ratchet.jl` and `dev/parity_baseline.toml` provide committed structural
regression patterns for every certified row.
At the original audited commit every committed lock through L88 (except unused L33) was
zero. At the 2026-07-22 validation, every current committed lock through L96 remains zero.
Key final locks added by the fresh audit:

- L84: numeric boxing requires an exact concrete Julia class;
- L85: constructors never discard supplied values or repair them with null;
- L86: SSA/Pi aliases of Julia `nothing` retain null semantics before conversion;
- L87: all builder/codegen branches and try-table catches retain symbolic label identity;
- L88: constant fields retain their exact runtime Julia classes and undefined captures reject.

The later locks L89–L96 preserve erased-boundscheck CFG edges, crossing-region
normalization/rejection, declarative framework roots, exact runtime predicates and bottom
edges, exact recovered-capture closed-world edges, structured diagnostic ledgers,
representation-correct `Type{T}` specialization, and explicit-IO semantics.

The ratchets also hold at R2=0 raw byte bridges, R16=0 external conversion ladders,
R18=0 all-Any dispatch signatures, R3=127 pre-emission static-type queries, R5=82
concrete representation queries, R7=109 intrinsic-local numeric operations, and R17=29
classified actual-type emission sites.

## Final executable evidence

The worktree was clean at implementation commit `e6114f8`. The final command was:

```sh
WT_TEST_CONCURRENCY=3 julia --project=. -e 'using Pkg; Pkg.test()'
```

Result on 2026-07-11:

- all ten shards green: 347 + 178 + 208 + 258 + 179 + 153 + 306 + 511 + 198 + 263;
- bounded differential fuzz: 3/3;
- LinearAlgebra 81/81;
- Dates 59/59;
- Random 19/19;
- Statistics 5/5;
- SparseArrays 39/39;
- ForwardDiff 27/27;
- StaticArrays 20/20;
- SimpleDiffEq 40/40;
- package result: `WasmTarget tests passed`.

This execution evidence proves the tested surface; it is not used as a substitute for
the independent source correspondence and locks above.

## Certification conclusion

For the declared scope and original audited revisions, the WasmTarget builder and
code-generation architecture was certified structurally aligned with the pinned dart2wasm
oracle. The bounded 2026-07-22 revalidation found no regression in the rechecked areas.
Unsupported excluded features remain explicit gaps, not hidden compatibility paths. Any future change
that reintroduces multiple compilation routes, numeric-depth branch APIs, value repair,
typeless boxing, silent fallback, or validation bypass must break a committed lock.
