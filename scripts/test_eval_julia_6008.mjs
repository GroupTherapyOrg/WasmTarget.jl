// PURE-6008: Test JS execution bridge — evalJulia() in WasmTargetRuntime
// Gap E: Codegen→Execute bridge
//
// Pipeline under test:
//   eval_julia_6007.wasm → evalJulia("1+1")
//     → eval_julia_wasm("1+1") → 90-byte inner module bytes
//     → WebAssembly.instantiate(bytes) → inner instance
//     → inner.exports["+"](1n, 1n) → 2n
//
// Ground truth (PURE-6003):
//   "1+1" → 2, "2+3" → 5, "10-3" → 7, "6*7" → 42

import { readFile } from 'fs/promises';
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { WasmTargetRuntime } = require(join(__dirname, '../browser/wasmtarget-runtime.js'));

// Ground truth from PURE-6003 (native Julia execution)
const GROUND_TRUTH = [
    { expr: "1+1",  expected: 2n },
    { expr: "2+3",  expected: 5n },
    { expr: "10-3", expected: 7n },
    { expr: "6*7",  expected: 42n },
];

async function main() {
    console.log("=== PURE-6008: JS Execution Bridge Test ===\n");
    console.log("Ground truth (PURE-6003):", GROUND_TRUTH.map(t => `${t.expr}=${t.expected}`).join(", "), "\n");

    const WASM_PATH = '/tmp/eval_julia_6007.wasm';

    // Step 1: Load eval_julia WASM module
    console.log("--- Step 1: Load eval_julia_6007.wasm ---");
    const rt = new WasmTargetRuntime();
    let evalInstance;
    try {
        const wasmBytes = await readFile(WASM_PATH);
        evalInstance = await rt.load(wasmBytes.buffer, "eval_julia");
        const fnCount = Object.keys(evalInstance.exports).filter(k => typeof evalInstance.exports[k] === 'function').length;
        console.log(`  Loaded: YES (${fnCount} exports)`);
    } catch (e) {
        console.log(`  FAIL: ${e.message}`);
        process.exit(1);
    }
    console.log();

    // Step 2: Test evalJulia() bridge for each case
    console.log("--- Step 2: evalJulia() bridge tests ---");
    let allCorrect = true;
    const results = [];

    for (const { expr, expected } of GROUND_TRUTH) {
        try {
            const result = await rt.evalJulia(evalInstance, expr);
            const correct = result === expected;
            if (!correct) allCorrect = false;
            console.log(`  evalJulia("${expr}") = ${result} (expected ${expected}) → ${correct ? "CORRECT" : "WRONG"}`);
            results.push({ expr, result, expected, correct });
        } catch (e) {
            allCorrect = false;
            console.log(`  evalJulia("${expr}"): ERROR - ${e.message}`);
            results.push({ expr, result: null, expected, correct: false });
        }
    }
    console.log();

    // Summary
    console.log("=== Summary ===");
    const passCount = results.filter(r => r.correct).length;
    console.log(`  ${passCount}/${results.length} expressions CORRECT`);

    if (allCorrect) {
        console.log("\n✓ PURE-6008: JS execution bridge CORRECT for all 4 expressions");
    } else {
        console.log("\n✗ PURE-6008: Some expressions FAILED");
        process.exit(1);
    }
}

main().catch(e => { console.error(e); process.exit(1); });
