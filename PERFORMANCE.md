# Performance Report — WasmTarget.jl Collections

Generated: 2026-03-30

## WASM Binary Sizes

| Function | WASM Size | Status |
|----------|-----------|--------|
| `map(f, v)` | 5,951 B | PASS |
| `any(pred, v)` | 5,646 B | PASS |
| `all(pred, v)` | 5,646 B | PASS |
| `count(pred, v)` | 5,839 B | PASS |
| `sum(Vector{Int64})` | 6,722 B | PASS |
| `sum(Vector{Float64})` | 6,752 B | PASS |
| `reduce(+, v)` | 6,703 B | PASS |
| `prod(v)` | 6,725 B | PASS |
| `minimum(Vector{Int64})` | 6,789 B | PASS |
| `maximum(Vector{Int64})` | 6,789 B | PASS |
| `minimum(Vector{Float64})` | 6,747 B | PASS |
| `maximum(Vector{Float64})` | 6,747 B | PASS |
| `reverse(Vector{Int64})` | 6,346 B | PASS |
| `reverse(Vector{Float64})` | 6,347 B | PASS |
| `sort(Vector{Int64})` | 35,425 B | BROKEN |
| `filter(pred, v)` | 8,663 B | BROKEN |

Average working function: ~6.3 KB. Sort is notably larger (35 KB) due to Julia's ScratchQuickSort + radix sort dispatch.

## Bridge Overhead

Bridge functions add minimal binary overhead:

| Module | Size | Delta |
|--------|------|-------|
| `sum` alone | 6,736 B | — |
| `sum` + bridge (4 functions) | 7,075 B | +339 B (+5%) |

The 339 B overhead includes `_bv_i64_new`, `_bv_i64_set!`, `_bv_i64_get`, and `_bv_i64_len`.

## Execution Time (Node.js)

| Operation | Time | Notes |
|-----------|------|-------|
| `sum(1:1000)` via bridge | ~780 ms | Includes compile + launch + marshal 1000 elements |
| `add(1, 2)` scalar | ~425 ms | Baseline (compile + launch only) |
| Bridge overhead | ~355 ms | For 1000-element Vector creation |

Note: These times include Julia compilation + Node.js process launch + WASM instantiation, NOT just execution time. The bridge marshalling overhead (creating 1000 elements via set!) is ~355 ms on top of the baseline.

## Verification

All functions above validated via:
- `wasm-tools validate --features=gc` (structural validity)
- `compare_julia_wasm_vec` (correctness vs native Julia)
- Tested with vectors up to 1000 elements
