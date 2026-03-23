# Playground Build Progress (REAL Codegen)

## Cheat History

### Prior Loops (Architecture B — pre-baked approach)
- Loops 1-5: Hand-emitted opcodes for specific functions (mul_int, add_int, etc.)
- `wasm_compile_i64_to_i64`: Mini-compiler with hardcoded intrinsic IDs → WASM opcodes
- `wasm_compile_flat`: Flat Int32 instruction buffer → WASM opcodes
- `wasm_compile_source`: Full parse+compile but still hand-emitted opcodes
- `eval_julia.jl`: Pre-baked CodeInfo per operation via @eval/QuoteNode

**All of the above are CHEATING per Rule 1.** They bypass the real codegen.

### What "REAL codegen" means
The REAL codegen is `compile_statement` + `compile_call` + `compile_invoke` + `compile_value`
in `src/codegen/`. These functions dispatch on IR node types via Julia's `isa` operator.
When compiled to WASM, `isa` becomes `ref.test` on WasmGC struct types.

## Current Session

### 2026-03-23: Session 1 — D-001 (Register IR Types)

**Goal**: Verify/ensure Core IR types compile as WasmGC structs with ref.test dispatch.

**Baseline**: 914 passed, 2 errored (pre-existing), 6 broken

**Status**: DONE

**Root cause found**: `compile_value` in `src/codegen/values.jl` treated Core.SSAValue, Core.Argument,
and Core.SlotNumber inside QuoteNodes as IR references (SSA slot lookups / argument loads) instead
of literal struct values. SSAValue(3) was compiled as `local.get` of SSA slot 3, not as `struct.new`
of an SSAValue struct.

**Fix**: In the QuoteNode handler (line 516), added special case for `Core.SSAValue`, `Core.Argument`,
`Core.SlotNumber` — compiles them as struct constants via `register_struct_type!` + `struct.new`.
Same fix in `infer_value_wasm_type` for type inference.

**Results**:
- 7 ref.test instructions emitted for 7 isa checks (ReturnNode, GotoNode, GotoIfNot, Expr, SSAValue, Argument, PhiNode)
- Runtime dispatch: all 5 standalone tests + combined dispatch function pass
- 914 tests pass, 0 failed, 2 errored (pre-existing), 6 broken — zero regressions

**WasmGC type mapping for IR nodes**:
| IR Type | WasmGC Struct | Notes |
|---------|---------------|-------|
| ReturnNode | (i32, mut anyref) | val is Any |
| GotoNode | (i32, mut i64) | Same struct as SSAValue/Argument |
| SSAValue | (i32, mut i64) | Distinguished by typeId field |
| Argument | (i32, mut i64) | Distinguished by typeId field |
| GotoIfNot | (i32, mut anyref, mut i64) | cond + dest |
| Expr | (i32, mut ref i8_arr, mut ref vec) | head + args |
| PhiNode | (i32, mut ref i32_vec, mut ref any_vec) | edges + values |

### 2026-03-23: Session 2 — D-002 (compile_value dispatch + field access)

**Goal**: Prove compile_value-style dispatch works in WASM: isa check → PiNode narrowing → field access.

**Status**: DONE

**What works**:
- `cv_field_dispatch(val::Any)::Int64` — dispatches on SSAValue, Argument, GotoNode from Any-typed param
- After `val isa Core.SSAValue` → PiNode inserts `ref.cast` → `struct.get` accesses `val.id`
- 10 `ref.test` instructions emitted for 7 IR type checks in `cv_type_tag`
- Cross-function dispatch via `compile_multi` with `@noinline` functions

**Runtime results** (9/9 pass):
| Test | Expected | Actual | Pattern |
|------|----------|--------|---------|
| SSAValue(42).id | 42 | 42 | isa → PiNode → struct.get field 1 |
| Argument(7).n | 7 | 7 | isa → PiNode → struct.get field 1 |
| GotoNode(99).label | 99 | 99 | isa → PiNode → struct.get field 1 |
| ReturnNode(nothing) → fallback | -1 | -1 | No match → default return |
| Type tag SSAValue | 1 | 1 | ref.test dispatch |
| Type tag Argument | 2 | 2 | ref.test dispatch |
| Type tag GotoNode | 3 | 3 | ref.test dispatch |
| Type tag ReturnNode | 4 | 4 | ref.test dispatch |
| Combined tags 1+2+3+4 | 10 | 10 | Cross-function accumulation |

**Test suite**: 924 passed, 0 failed, 2 errored (pre-existing), 6 broken — zero regressions

**Note**: Vector{Any} construction inside WASM hits `Memory{Any}` API (Julia 1.12), which is not yet supported. This is separate from the dispatch pattern and does not block D-003+.
