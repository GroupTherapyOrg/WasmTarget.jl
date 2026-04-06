# Core Functions Coverage — Guardrails

## Rules

1. **NEVER reimplement a Base function in test code.** Fix the compiler, wire dispatch, add overlays, or add JS bridges.
2. **NEVER return fake values from stubs.** If you can't implement it, emit UNREACHABLE with a clear comment.
3. **NEVER claim something works without a compare_julia_wasm test proving it.**
4. **ALWAYS read progress.md before starting** — it has the full history and audit results.
5. **ALWAYS run full test suite after BUILD stories** — verify no regressions.
6. **Audit FIRST.** DISCOVER stories document what works and what doesn't. Only after audit do you BUILD fixes.
7. **For string functions**: Use wrapper functions with hardcoded string constants. JS can't marshal strings to WasmGC refs.
8. **For collection functions**: Use compare_julia_wasm_vec for Vector args. Use wrapper functions for closures.
9. **Minimal changes only.** Each fix has an estimated LOC. If writing 10x more, STOP and reassess.
10. **Test ALL kwargs.** A function with 3 kwargs needs at least 4 tests (default + each kwarg).

## Classification System

- **WORKS_FULL**: Compiles + validates + correct runtime for ALL kwargs/closures
- **WORKS_BASIC**: Compiles + validates + correct for basic call, but some kwargs fail  
- **COMPILES_WRONG**: Compiles + validates but wrong runtime result
- **FAILS_VALIDATE**: Compiles but wasm-tools rejects
- **STUBS**: Compiles but inner methods hit `unreachable` stub
- **FAILS_COMPILE**: Doesn't compile at all
- **BLOCKED**: Fundamentally impossible without JS bridge (e.g., PCRE2, IO)

## Testing Patterns

```julia
# Scalar args — direct
compare_julia_wasm(abs, Int64(-5))

# String args — wrapper with hardcoded constants
str_lower() = lowercase("HELLO")
compare_julia_wasm_manual(str_lower, (), "hello")

# Vector args — via bridge  
compare_julia_wasm_vec(sum, [1, 2, 3])

# Closures — wrapper
filter_even(v::Vector{Int64})::Vector{Int64} = filter(iseven, v)
compare_julia_wasm_vec(filter_even, [1, 2, 3, 4])

# Batch — multiple test cases
compare_batch(abs, [(Int64(5),), (Int64(-3),), (Int64(0),)])
```

## Commit Format
```
CF-XXXX: Description
```

## Reference Files
- PRD: `wasmtarget-corefns-prd.json`
- Progress: `wasmtarget-corefns-progress.md`
- Prior gap analysis: `wasmtarget-gapfix-progress.md` (context only)
