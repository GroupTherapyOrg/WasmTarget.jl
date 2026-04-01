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

### Next Priority
**WBUILD-7000**: Trace InexactError invoke path in codegen to find where the SSA local assignment breaks.
