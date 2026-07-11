# WasmTarget.jl ↔ dart2wasm structural certification

Status: **ACTIVE AUDIT — not yet a final parity certificate**

Audit date: 2026-07-10

WasmTarget commit audited: `8d3550d`
Dart architectural oracle: dart-lang/sdk `upstream/main` at
`6f00c0695c7c2cdddf16776b9a1c272bba70045a`

This document was rebuilt from the current sources. It deliberately does not inherit
green claims from the previous certification. A row is green only when current source,
a machine lock, and current execution evidence all support it.

## Scope

Builder and code-generation structure are in scope. Async, FFI, threads, deferred/JS
glue, and host integration remain explicitly excluded. Exclusion does not permit a fake
value: unsupported reachable constructs must reject, and sound dead branches may emit a
diagnosed validating trap.

## Current source-to-source audit

| Invariant | Current dart2wasm oracle | Current WasmTarget implementation | Evidence | Result |
|---|---|---|---|---|
| Typed validating instruction builder | `pkg/wasm_builder/lib/src/builder/instructions.dart:172,474-554`; `_verifyTypes` is called by instruction methods | `src/builder/instr_builder.jl:51,117`; every emission updates and checks the abstract operand stack | Locks L6, L13; clean `Pkg.test()` | ✅ |
| Typed expression channel | `pkg/dart2wasm/lib/code_generator.dart:28,60,677`; `CodeGenerator`/`AstCodeGenerator` carry expected and produced value types | `src/codegen/values.jl:857-905`; `emit_value!` derives the actual type from emission and owns expected-type wrapping | Locks L4, L9; R17 ratchet | ✅, remaining unwrapped call sites ratcheted |
| One conversion funnel | `pkg/dart2wasm/lib/translator.dart:1597-1655`; `convertType` owns drop, unreachable, null-check, cast, box, and unbox | `src/codegen/values.jl:400+`; `convert_type!` is the coercion funnel and the expected-value wrapper owns static source typing | Locks L1, L2, L5; R7/R16 ratchets | ✅, intrinsic-local numeric ops remain tracked debt |
| One production compilation route | dart compilation constructs one translator/module strategy and all bodies use the `CodeGenerator` interface | `compile_module` → `_compile_module_trim` → `_compile_closed_world_plan` → exactly one production `generate_body(ctx)` call | Lock L17; legacy/self-host/byte-shell compilers deleted | ✅ |
| One structured control-flow lowering | current code generator emits structured Wasm through one visitor family | `generate_body` → `generate_structured` → stackifier; eight legacy flow generators are absent | Lock L3 | ✅ |
| Class IDs and range tests | `class_info.dart:27,667-724,872-1055`; field 0 is classId and numbering/ranges drive tests | DFS type IDs, classId field 0, `emit_classid_range_check!` at `values.jl:684` | Locks L5/L10; class/dispatch tests | ✅ for certified representations |
| Top/Object identity layout | `class_info.dart:27,29,540-580`; Top owns immutable classId, Object adds mutable identityHash; primitive boxes remain below Top | separate Top/Object types; ordinary structs, tuples, and Array wrappers inherit `{classId, identityHash}` at registration; value boxes remain Top-only; closure contexts remain internal; `jl_object_id` reads/writes field 1 | Locks L20/L28; mutable-object identity differential; focused shards and external validation | ✅ for current representations; final clean whole-suite rerun remains required |
| Recursive type groups | wasm_builder `builder/types.dart:45-70`, `serialize/sections.dart:45-66`; definitions may reference only the same or earlier contiguous recursion group | self-recursive structs reserve their final index after supertypes/dependencies, group the contiguous struct/array/wrapper interval, then fill the reserved definition; serializer rejects unordered/noncontiguous groups | Lock L29; direct-recursive and `Vector{Self}` execution plus external validation | ✅ for Julia-realizable recursive layouts |
| Dynamic dispatch table | `dynamic_dispatch_table.dart:25+`; classId/selector-based table construction | one selector table, classId + offset + indirect call; FNV dispatch deleted | Lock L10; dispatch suites | ✅ for current supported call surface |
| Module strategy | `modules.dart:182,219`; default and deferred strategies are explicit | one monolithic closed-world Wasm module | Deferred loading is excluded | ✅ within declared monolithic scope |
| Loud unsupported behavior | dart `unimplemented` paths diagnose and trap; `convertType` has no guess-and-continue arm | `record_unsupported!`/`emit_unsupported_stub!` distinguish fatal wrong-value replacements from diagnosed traps | Locks L8, L14-L19; soundness tests | ✅ |
| No validator-as-repair loop | dart relies on its builder; external validation is not a repair phase | builder validity is unconditional; `wasm-tools` is an independent opt-in cross-check and never rewrites bodies | Locks L6/L7/L14 | ✅ |

## Current execution evidence

Clean worktree command:

```sh
WT_TEST_CONCURRENCY=2 julia --project=. -e 'using Pkg; Pkg.test()'
```

Result on 2026-07-10:

- all ten shards green: 347 + 169 + 199 + 257 + 179 + 153 + 306 + 495 + 198 + 261;
- bounded differential fuzz: 3/3;
- LinearAlgebra 81/81, Dates 59/59, Random 19/19, Statistics 5/5;
- SparseArrays 39/39, ForwardDiff 27/27, StaticArrays 20/20,
  SimpleDiffEq 40/40;
- package result: `WasmTarget tests passed`.

This proves the tested executable surface. It does not by itself prove structural parity;
the source rows and locks above are independently required.

## Remaining blockers to a final green certificate

1. Close current builder/codegen gaps that are not excluded, including the remaining
   mixed-container `_apply_iterate` audit. Runtime-length composition
   (including mixed Any-storage escape) and packed i8/i16 arrays are now executable and
   locked; a diagnosed remaining failure is sound but is not feature parity.
2. Drive R17 unwrapped emissions and R16 external conversion calls to their justified
   architectural floors, with every remaining site classified against current dart.
3. Re-audit dynamic/static dispatch and constant construction against current files
   (`dynamic_dispatch_table.dart`, `static_dispatch_table.dart`, `constants.dart`) after
   the Object migration, then add exact locks for the final invariants.
4. Run the clean full suite, differential matrix, external validators, and this audit
   again at the final candidate commit.

Until all five blockers are closed, this file is an evidence-backed progress audit—not a
claim of strict 1:1 parity.
