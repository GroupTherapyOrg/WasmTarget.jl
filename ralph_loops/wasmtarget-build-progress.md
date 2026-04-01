# Compiler Gap Closure Progress

## 2026-03-31: Initial State Assessment

### Baseline
- **1527 pass, 31 fail, 122 error, 6 broken**
- Recent WBUILD iterations (1-6) completed: 128-bit ints, hash, Dict/Set, splatting

### Completed Work (prior iterations)
- **WBUILD-5000/5003**: 128-bit integer ops fixed (LEB128 encoding, mul carry, shl/lshr edge cases). sin(1e10) now works via Payne-Hanek.
- **WBUILD-5100/5102**: hash() for Int64 and Float64 — pure Julia bitwise mixer compiles correctly. 18 tests added.
- **WBUILD-5200/5204**: Dict{Int64,Int64} and Set{Int64} work end-to-end. 24 tests (insert, get, haskey, delete, rehash, stress 200 entries).
- **WBUILD-5300/5301**: Vector splatting via _apply_iterate. +(v...) and *(v...) for Int64/Float64. 12 tests.
- **Conditionals fix (iteration 6)**: `has_ref_producing_gc_op` guard prevents phi type confusion when string constants start with i32.const operand.

### Failure Categories (post M5/5.x work)
1. **InexactError invoke** (3 tests): Float32(Int32(Float64(x))) returns 0. Root cause: fptosi SSA value not stored in local when error-path invoke fails compilation.
2. **Math stackifier** (~150 tests): log/atan return wrong values. exp2/log2/etc. produce invalid WASM.
3. **Stubs returning fake values**: parse_int_literal→0, str_substr→unchanged, Pointer.ptr→0.

### Key Learning
The `InexactError` pattern appears in ALL bounds-checked type conversions (Int32(Float64(x)), Int64(Float32(x)), etc.). This is HIGH impact — fixing it will likely fix many real-world Julia functions that do numeric conversions.

## 2026-03-31: M7 InexactError + Type Conversion Fix — COMPLETE

### WBUILD-7000 (DISCOVER): InexactError invoke compilation path traced

**IR Pattern** for `Int64(Float64(x) * 2.0)`:
```
1: add_int(_2, 3)           ← a = x + 3
2-3: sitofp, mul_float      ← Float64(x) * 2.0
4-14: Bounds checking        ← InexactError guards
15: fptosi(Int64, %3)        ← b = Int64(float_result)
16: goto %20                 ← skip error path
17-19: InexactError + throw   ← error path
20: add_int(%1, %15)         ← a + b
21: return %20
```

**Root cause found**: In `generate_stackified_flow` (stackified.jl), the GotoNode handler has an `exits_outermost` optimization (WBUILD-3001) that replaces `br` with `local.get <ret_local>; return`. The bug: it picks `ssa_locals[%20]` = local 12 as the return value, but %20 is computed IN the destination block (add_int). The local is still 0 (uninitialized default) when the return executes.

### WBUILD-7001 (BUILD): Fix applied

**Fix**: In the `exits_outermost` path, only use `ssa_locals[vid]` when the SSA is defined OUTSIDE the destination block. If `vid` is between `dest_start` and `dest_end`, fall through to the `br` path instead.

Changed lines 2024-2027 in stackified.jl — added bounds check `if vid < dest_start || vid > dest_end`.

### WBUILD-7002 (VERIFY): All tests pass

- **Before**: 1527 pass, 31 fail, 122 error, 6 broken
- **After**: 1558 pass, 0 fail, 122 error, 6 broken
- **+31 tests fixed, 0 regressions**

The fix resolved ALL 31 pre-existing test failures. The `exits_outermost` bug affected any function where the stackifier was used and the destination block had computation (not just returning a phi local).

### Key Learning
The `exits_outermost` optimization was introduced to avoid falling through to `unreachable` after all blocks close. But it incorrectly assumed SSA locals defined in the destination block were already computed. The fix is simple: check whether the SSA is defined inside or outside the destination block.

### Next Priority
**WBUILD-8000** (M8): Audit hardcoded-return stubs.
