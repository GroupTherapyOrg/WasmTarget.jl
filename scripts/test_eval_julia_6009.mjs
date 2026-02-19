// PURE-6009: Verify eval_julia.wasm at stable browser/ path
// Tests that browser/eval_julia.wasm loads and evalJulia() works correctly.
// This simulates what the playground.html run() function does.

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

// Regex matching binary integer arithmetic (mirrors playground.html run() logic)
const BIN_INT_RE = /^(-?\d+)\s*([+\-*])\s*(-?\d+)$/;

async function main() {
    console.log("=== PURE-6009: Playground wiring test (stable browser/ path) ===\n");

    const WASM_PATH = join(__dirname, '../browser/eval_julia.wasm');

    // Load eval_julia.wasm from stable browser/ path
    console.log("--- Loading browser/eval_julia.wasm ---");
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

    // Simulate playground run() logic: binIntMatch → evalJulia
    console.log("--- Simulating playground run() for binary integer expressions ---");
    let allCorrect = true;
    for (const { expr, expected } of GROUND_TRUTH) {
        const binIntMatch = expr.match(BIN_INT_RE);
        if (!binIntMatch) {
            console.log(`  ${expr}: SKIP (no binIntMatch — would fall through to pipeline.wasm)`);
            continue;
        }
        try {
            const result = await rt.evalJulia(evalInstance, expr);
            const correct = result === expected;
            if (!correct) allCorrect = false;
            console.log(`  evalJulia("${expr}") = ${result} (expected ${expected}) → ${correct ? "CORRECT" : "WRONG"}`);
        } catch (e) {
            allCorrect = false;
            console.log(`  evalJulia("${expr}"): ERROR - ${e.message}`);
        }
    }
    console.log();

    console.log("=== Summary ===");
    if (allCorrect) {
        console.log("✓ PURE-6009: Playground wiring CORRECT — eval_julia.wasm at stable path, evalJulia() works");
    } else {
        console.log("✗ PURE-6009: Some expressions FAILED");
        process.exit(1);
    }
}

main().catch(e => { console.error(e); process.exit(1); });
