# Architecture B Build Progress

## 2026-03-19: Session 1

### Existing State
- Architecture A: DONE (20/20 functions, server CodeInfo → browser codegen)
- Architecture C: DONE (20/20 functions, server parse+lower → browser typeinf+codegen)
- Architecture B: **WORKING** for binary arithmetic (20/20 groups, 100/100 cases)

### Key Discovery: eval_julia.wasm IS Architecture B

`browser/eval_julia.wasm` (2.2MB, 217 exports) already implements the full zero-server pipeline:
- Input: source string (WasmGC array<i32>)
- Pipeline: byte-level parse → pre-resolved typeinf → compile_from_codeinfo → WASM bytes
- Output: WasmGC vector of WASM bytes (inner module)
- Only import: Math.pow

The `wasmtarget-runtime.js` provides:
- jsToWasmString() — JS string → WasmGC array<i32>
- evalJulia() — full pipeline: string → compile → instantiate → execute

### What Works NOW
- Binary integer arithmetic: +, -, * on Int64 (via pre-baked compile_from_codeinfo)
- Binary float arithmetic: +, -, *, / on Float64
- Unary function calls: sin, abs, sqrt
- ALL compilation runs in WASM — ZERO server dependency

### What's Missing for Full Function Support
- Function definitions (e.g., `f(x::Int64) = x*x + Int64(1)`)
  - Requires full JuliaSyntax parser (parse_stmts hits unreachable for *)
  - Requires JuliaLowering → CodeInfo production
  - Requires dynamic type inference (not just pre-baked)
- Multi-statement expressions (e.g., `x*x + 1`)
- User-defined types, control flow, etc.

### Available WASM Modules
| Module | Size | Exports | Valid? | Purpose |
|--------|------|---------|--------|---------|
| browser/eval_julia.wasm | 2.2MB | 217 | YES | **Arch B entry point** |
| unified-module.wasm | 720KB | 198 | YES | Full pipeline (parser+lower+typeinf+codegen) |
| parser_module.wasm | 520KB | 84 | YES | JuliaSyntax parser only |
| self-hosted-codegen-e2e.wasm | 132KB | 56 | YES | Codegen + IR constructors |
| frontend_module.wasm | 24KB | 18 | YES | Lowering helpers |
| lowering.wasm | 52KB | N/A | NO | Type index 82 OOB |

### Architecture B Test Infrastructure
- `scripts/e2e_demo_arch_b.cjs` — E2E demo (10/10 binary ops, PASS)
- `scripts/run_arch_b_tests.cjs` — Regression suite (20 groups, 100 cases, ALL PASS)
- `test/selfhost/e2e_arch_b_tests.jl` — Julia test harness (1/1 tests pass)

### Learnings
1. eval_julia.wasm uses pre-resolved CodeInfo (embedded at compile time via @eval/QuoteNode)
2. Runtime compile functions call compile_from_codeinfo directly in WASM
3. The JS evalJulia wrapper builds canonical "1OP1" strings for dispatch
4. ParseStream construction works in WASM but parse_stmts hits unreachable for multiplication
5. Two eval_julia builds exist: browser/ (WasmGC string API) and output/ (Vector{UInt8} API)

### Stories Completed
- PREP-001: Audit unified module exports ✅
- PREP-002: Test eval_julia_wasm patterns ✅
- WIRE-001: Build Architecture B E2E demo ✅
- TEST-001: Build 20-group regression suite ✅

### Next Steps (Priority)
1. Fix parse_stmts unreachable for multiplicative precedence
2. Add multi-statement expression support to eval_julia
3. Add function definition parsing and lowering
4. Wire full JuliaSyntax → JuliaLowering → typeinf → codegen in browser
