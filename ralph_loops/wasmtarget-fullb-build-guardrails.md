# Architecture B Build Guardrails

## Rules

1. **MEASURE BEFORE BUILDING** — Don't guess what WASM modules export. Instantiate them, call functions, trace call paths, produce JSON reports.

2. **NO REGRESSIONS** — 910+ tests must still pass. Run `julia +1.12 --project=. test/runtests.jl` before declaring done.

3. **ARCHITECTURE A/C MUST STILL WORK** — `node scripts/e2e_demo_arch_a.cjs` and `node scripts/e2e_demo_arch_c.cjs` must still pass.

4. **INCREMENTAL** — Test each pipeline stage independently before wiring them together. Parse alone. Lower alone. Typeinf alone. Codegen alone. Then chain.

5. **COMMIT EVERY 10 MINUTES** — First commit within 5 minutes. Push WasmTarget.jl changes.

6. **NO WORKAROUNDS** — If a WASM function is missing, add it to the compiler. Don't fake it in JS.

7. **UNIFIED MODULE** — Prefer the unified-module.wasm (720KB, 198 exports) over separate per-stage modules. It has everything.

## Known Risks

- Parser needs ParseStream/ParseState construction from JS — may need new WASM exports
- Lowerer needs SyntaxGraph construction — may need new WASM exports
- Data format bridging between stages (WasmGC structs) — may need JS glue
- lowering.wasm is INVALID (Type index 82 out of bounds) — use unified module instead
- Stackifier bug still exists for complex functions — not blocking for i64 arithmetic
