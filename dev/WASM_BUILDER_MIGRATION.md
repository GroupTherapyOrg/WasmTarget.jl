# WasmTarget → dart2wasm-style typed instruction builder — migration plan

**Branch:** `wt-wasm-builder`  ·  **Goal:** replace WT's emergent/heuristic operand-stack
management with **one** explicit, self-validating instruction builder mirroring
dart2wasm's `pkg/wasm_builder` (both target WasmGC). **This is a REPLACEMENT, not an
addition** — bloat is the cardinal sin. The end state is a single emission layer; the
raw `push!(bytes, Opcode.X)` idiom, the dead post-hoc validator, the `fix_*` byte-rewrite
passes, the stack-balance patch sites, and one of the two flow generators are all
**deleted** as we migrate.

## Why (the architecture verdict)

Today WT spills most SSA values to wasm locals (the right default — same base as LLVM/Go),
but the *residual* stack threading + balance is **emergent**: kept correct by ~40-60
per-case heuristics (`haskey(ssa_locals,idx)` guards, orphan-detection, re-push sites,
`bytes=UInt8[]` resets) plus **7 post-hoc `fix_*` byte-rewrite passes**, verified only
afterward by an external `wasm-tools validate` (binary accept/reject, no emit-site trace).
There is **no live model of operand-stack height/contents during emission**. That is the
class of bug behind "values remaining on stack at end of block" (e.g. SimpleTsit5 +
Vector-state on Julia 1.13: a Vector `.ref`-write memref is stack-threaded into a following
`array.set` with no IR-level use, so "keep" vs "drop" are indistinguishable at the IR
level — see `test/fuzz/FINDINGS.md`).

The tried-and-true fix (LLVM `RegStackify`+`ExplicitLocals`, Binaryen's tree IR, dart2wasm's
validated `InstructionsBuilder`): **default values to locals; let an explicit, type-directed
stack model decide/track what rides the operand stack.** dart2wasm — WT's stated inspiration —
does exactly this: its `InstructionsBuilder` keeps `_stackTypes` + `_labelStack`
(per-block `baseStackHeight`) + `_reachable`, validates every op's pop/push against an IR
type lattice (`isSubtypeOf`), derives GC-op stack effects from the resolved `StructType`/
`ArrayType`, and `_verifyEndOfBlock` asserts `height == base + outputs` at every `end` —
turning "values remaining on stack" into an immediate build-time error.

## The decisive realization (why this is re-aim, not green-field)

WT **already has `src/builder/`** (`types.jl`, `writer.jl`, `instructions.jl`,
`validator.jl`). `builder/validator.jl::WasmStackValidator` is **already a dart2wasm-style
stack model** (push/pop, label stack with loop-vs-block target types, `wasm_types_assignable`,
GC-instruction rules). It is just **pointed at the output** — `validate_emitted_bytes!`
(`generate.jl:14-109`) re-parses *finished* bytes, resets per statement, skips all GC/call/
control opcodes, self-suppresses underflows, and only `@debug`s (`generate.jl:240-242`). So:

> **The migration re-aims `WasmStackValidator` from "scan finished bytes" to "validate as
> instructions are appended," merges the byte buffer into it (each `emit` both appends bytes
> AND does pop/push), makes it THROW with Julia source context — and then deletes everything
> the old emergent approach needed.** ~70% of the type logic already exists.

## Target architecture (mirror dart2wasm's 3 layers, one direction, no extra layers)

```
builder/  (mutable build + validate)  ──▶  ir/  (immutable, self-serializing)  ──▶  serialize/ (LEB128 + sections)
```
WT already has these as `src/builder/{instructions,types,writer,validator}.jl`. We
consolidate into:
- **`InstrBuilder`** (re-aimed `WasmStackValidator` + the byte buffer): state
  `{code, stack::Vector{WasmValType}, labels::Vector{Label}, reachable::Bool, locals, type_registry}`.
  One method per opcode family — `i32_add!(b)` appends `0x6A` AND pops i32,i32 / pushes i32.
  GC ops read the resolved `StructType`/`ArrayType` to compute their effect
  (`struct_new!(b, s)` consumes `length(s.fields)` typed values, pushes `(ref s)`).
  Validators to port verbatim from dart2wasm: `verify_types` (base-height underflow guard +
  subtype check), `check_stack_types`, `verify_end_of_block` (`height == base + outputs`),
  `verify_branch_types` (target = outputs for block/if, **inputs for loop**), reachability
  (skip checks after `unreachable`/`br`/`return`, restore at `end`/`else`). Tighten
  `wasm_types_assignable` to real WasmGC subtyping via the registry (this alone replaces ~5
  `fix_*` passes).
- IR/serialize layers stay (`to_bytes`, `WasmWriter`, `Opcode` consts) — those are
  legitimate binary serialization of an already-built module, **not** in the deletion scope.

## The deletion campaign (anti-bloat — these GO)

- **Dead validator:** `validate_emitted_bytes!` + the `@debug` gate (`generate.jl:14-109`,
  `240-242`), call site `conditionals.jl:3297`. (Keep & re-aim the `WasmStackValidator`
  *logic*; delete the re-scanner wrapper.)
- **7 `fix_*` byte-rewrite passes** + tail-rewrites + `strip_excess_after_function_end` + the
  byte-reparse helpers: `generate.jl:255,296,517,665,968,1266,1377,179-189,1078,840,947`,
  `stackified.jl:73`. A live stack model makes every one unnecessary.
- **Stack-balance patch sites:** memoryrefset! re-push guard (`calls.jl:3687`); setfield!/
  setproperty! re-pushes (`calls.jl:4073,4101,4256,4267`); orphan-detection + leading-pair
  stripping (`statements.jl:1408-1496,1498-1537`); memoryrefnew{Nothing} double-DROP
  (`statements.jl:1543-1560`); DROP+UNREACHABLE sniffing (`statements.jl:1576-1593`); the ~20
  `bytes=UInt8[]` "clear pre-pushed args" resets in `calls.jl`.
- **Flow-generator duplication:** `flow.jl`'s pattern-matched family
  (`generate_loop_code`/`generate_if_then_else`/`generate_branched_loops`/
  `compile_nested_if_else`, `flow.jl:53,918,1938,2440`) → **consolidate onto the stackified
  path** (`stackified.jl:5,198`, the general one that already handles phi locals). One flow
  lowering, done *during* the flow migration, not as separate churn.

KEEP (genuine semantics, re-expressed against the builder): `Union{}`→`UNREACHABLE`
(`statements.jl:1563-1570`), strict-mode stub emission, `haskey(ssa_locals,idx)` as a
*liveness* query (just not as a stack-consumption proxy). KEEP `validate_wasm_bytes`
(`wasm-tools validate`, `WasmTarget.jl:386`) — the builder validates at emission (precise
source context), wasm-tools validates the final binary (authority); different stages, not
redundant. Add no third validator.

## Phased plan (each phase: migrate an entry point AND delete the debt it served, same PR)

- **Phase 0 — found the sole new API.** Re-point `ctx.validator` → `ctx.builder::InstrBuilder`;
  move the byte buffer into it; convert validate-methods into emit-methods that THROW on
  mismatch; tighten subtyping via the registry. **Delete `validate_emitted_bytes!` + the
  `@debug` gate now** (nothing else uses them). Builder exercised by new unit tests only.
- **Phase 1 — `compile_value!`** (`values.jl`, leaf, most-reused). Delete raw idiom there.
- **Phase 2 — `compile_call!` + `compile_invoke!`** (`calls.jl`/`invoke.jl`, the mass).
  Delete the re-push + `bytes=UInt8[]` reset sites in the same PRs (split by call-family).
- **Phase 3 — `compile_statement!` + `compile_new!`.** Replace orphan/strip/double-DROP with
  the deterministic rule: `surplus = height(b) - height_before`; SSA has a local →
  `local_set!` (consumes 1) + `drop!` the rest; else `drop!` all surplus.
  **Acceptance gate:** flip `simplediffeq_diff.jl` SimpleTsit5-Vector `@test_skip` → `@test`
  on 1.13; it must compile clean.
- **Phase 4 — flow + consolidation.** Block/label scoping on the builder; route ALL flow
  through the stackified path; retire the `flow.jl` family; **delete the 7 `fix_*` passes**.
  `generate_body` returns `b.code` directly.
- **Phase 5 — sweep the remainder** (`int128.jl`, `dispatch.jl`, `strings.jl`, `unions.jl`,
  `conditionals.jl`, `types.jl`, the 47 `emit_*` helpers). Port each, delete its raw body.
- **Phase 6 — lock it.** CI guard (extend `loop_guard.sh`): fail if
  `push!(.*bytes, Opcode\.` reappears in `src/codegen`. Re-verify self-host
  (`to_bytes_no_dict`) + trim paths.

## DONE looks like

- One emission API (`InstrBuilder`); `grep 'push!(.*bytes, Opcode\.' src/codegen` → empty.
- Dead validator, 7 `fix_*` passes, all stack-balance patch sites: deleted.
- One control-flow lowering (stackified); `flow.jl` pattern family retired.
- `WasmStackValidator`'s type logic survives *inside* the builder (re-aimed, not duplicated).
- SimpleTsit5 + Vector-state compiles clean on 1.13; the `@test_skip` gate is flipped back to
  `@test`; the FINDINGS "Vector-state ODE 1.13" entry is closed.

## Anti-bloat guardrails (where duplication WILL try to creep in)

1. Don't keep `emit_*`/`WasmStackValidator` as a parallel system — merge into the builder.
2. Don't add the builder and delete `fix_*`/patches "later" — each dies with its entry point.
3. Don't consolidate the flow generators as standalone churn — do it on the builder, Phase 4.
4. Don't duplicate validation — emission-time (builder) + final-binary (wasm-tools), no third.
5. `to_bytes`/`WasmWriter` byte-`push!` in `builder/` are serialization, NOT in scope — scope
   the CI guard to `src/codegen` instruction emission.

## Reference

Full dart2wasm `wasm_builder` blueprint (class/file map, the InstructionsBuilder method
inventory by family with stack effects, the validation contract, the rec-group/type-section
model) and the full WT emission inventory (per-file `push!`/`Opcode` counts, the patch-debt
catalogue with file:line, the flow-generator analysis) are in the planning research; the
crux to replicate is the **type-directed GC stack-effect computation** (`struct_new` reads
`StructType.fields`) and the **`_verifyEndOfBlock` balance invariant**.

## Progress log (leaf-first migration, branch `wt-wasm-builder`)

Verification recipe per batch (regression-free guarantee = **byte-identical** output):
`/tmp/str_digest.jl` compiles a corpus → sha256; `git stash` the migration, build
baseline, `git stash pop`, rebuild, `diff`. Then re-run with `WT_BUILDER_STRICT=1` to
prove the live model AGREES (no `StackImbalanceError`, identical bytes).

- **compile_condition_to_i32** (`values.jl`) — first real-codegen migration. Establishes
  the shim pattern: a produce-on-stack fragment builds into a fresh `InstrBuilder`,
  bridges the un-migrated `compile_value` via `emit_raw!(…; pushes=[infer_value_wasm_type])`,
  returns `builder_code(b)`. Callers unchanged (`::Vector{UInt8}`).
- **unions.jl** (whole file) — `emit_wrap_union_value` + `emit_unwrap_union_value`.
  Establishes the consume-from-stack pattern via `seed_input!` (model the value the
  un-migrated caller left on the stack). 0 raw emit sites remain.
- **strings.jl** — `compile_string_concat_with_locals` + `compile_string_equal`
  (control-flow-heavy: if/else/block/loop/br). Deleted dead `compile_string_concat`
  inline body (~70 lines built `bytes` then discarded it → thin delegator).

### Builder API added during migration (single API, dart2wasm-faithful)
- `ref_null!(b, rt::RefType)` / `ref_cast!(b, rt::RefType, nullable)` — abstract heaptypes
  (any/i31/array/struct): the enum value IS the on-wire byte → push raw, not LEB.
- `seed_input!(b, types)` — model upstream-produced stack values, no bytes.
- `_wt_builder_strict()` — collect by default (regression-free), hard-gate on `WT_BUILDER_STRICT`.

### BUG found + fixed via migration (the payoff)
`block!`/`loop!`/`if_!` LEB-encoded the blocktype → `if_!(0x7F)` emitted `04 ff 00`
instead of the correct single byte `04 7f`. Value-type/void blocktypes are single
on-wire bytes; `ConcreteRef` results are multi-byte (`0x63/0x64`+idx). Now encode via
the SAME `encode_block_type` the rest of codegen uses. Regression-guarded in the
InstrBuilder testset. (This is exactly why we migrate onto a typed model: latent
emit bugs surface at the emit layer with clarity.)

### Next targets (remaining are large atomic units)
`compile_value` (values.jl) → calls.jl/invoke.jl dispatch → int128.jl → statements.jl →
the flow generators (conditionals.jl/flow.jl/stackified.jl — these reach the 1.13
Vector-state ODE acceptance gate). The `emit_*!(bytes,…)` helpers (types.jl/strings.jl)
are NOT standalone leaves — delete them top-down as their callers migrate.

## Instruction-IR ADT landed (dart2wasm ir/ + serialize/ — the missing layer)

The builder was emitting bytes directly, collapsing dart2wasm's 3 layers into 1. Now
faithful: `src/builder/instr_ir.jl` defines a sealed `WasmInstr` ADT (submodule
`InstrIR`), ONE struct per wasm instruction, with per-class `encode!` (= dart2wasm
`serialize`) + `mnemonic` (= `printTo`) by native multiple dispatch. NATIVE, not Moshi:
dart2wasm uses per-class virtual methods whose 1:1 Julia map is dispatch, and it's
dependency-free (freeze/notarize story). `InstrBuilder` records `Vector{WasmInstr}`
(ir/), `builder_code` serializes it (serialize/). Typed-method API + all validation
UNCHANGED → the 3 migrated files needed no edits. `builder_disasm`/`builder_diagnose`
now emit symbolic WAT. Verified BYTE-IDENTICAL to the original raw-emission baseline;
strict-mode agrees through the IR path. THIS is the dart2wasm-architecture gap, closed.

## compile_value (values.jl) — deferred to a DEDICATED pass (not a budget-end rush)

WHY care: it's the central value emitter (~1100 lines, 216 sites, ~25 value-kind
branches) AND it BRANCHES ON THE RAW BYTES of recursive results
(`any(b==GC_PREFIX for b in elem_bytes)`, `elem_bytes[1]==I32_CONST`,
`elem_bytes[end]==UInt8(ExternRef)`), has nested `bytes`-helpers (`emit_array_default!`,
`compile_memory_elements!`), external `bytes`-helpers (`emit_type_id!`,
`_narrow_generic_local!`), a depth-guard try/finally, and rare branches (Dict/Vector/
Memory/struct constants, primitive bitcast, TypeName/Module/Function-singleton) that a
mini-digest can't exercise. Migration plan: (1) give the external bytes-helpers an
`InstrBuilder` form (or bridge via emit_raw with known stack effect); (2) the
byte-inspection stays (compile_value still RETURNS bytes via builder_code, so callers'
inspection works); (3) verify against the BROAD corpus `/tmp/cv_digest.jl` (20 value
kinds: Char, all int widths, Int128/UInt128, floats, strings, Symbol, Tuple, unions,
loops) AND run the full test suite (the real oracle for the rare branches). Baseline
captured in `/tmp/cv_baseline.txt`.
