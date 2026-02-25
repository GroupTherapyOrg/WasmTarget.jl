// PURE-6027: Test freshly compiled arith module (with dead code guard fix)
// Ground truth: eval("1+1")=2, "2+3"=5, "10-3"=7, "6*7"=42

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    const wasmPath = '/tmp/eval_arith_fresh.wasm';
    const bytes = readFileSync(wasmPath);
    console.log(`Module: ${bytes.length} bytes (${(bytes.length/1024).toFixed(1)} KB)`);

    const { instance } = await WebAssembly.instantiate(bytes, {
        Math: { pow: Math.pow }
    });
    const ex = instance.exports;
    const funcExports = Object.keys(ex).filter(k => typeof ex[k] === 'function');
    console.log(`INSTANTIATE SUCCESS (${funcExports.length} func exports)`);

    // Helper: create WasmGC byte vec from JS string
    function jsToWasmBytes(str) {
        const enc = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](enc.length);
        for (let i = 0; i < enc.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, enc[i]);
        }
        return vec;
    }

    // Test ground truth expressions
    const testCases = [
        ["1+1", 2],
        ["2+3", 5],
        ["10-3", 7],
        ["6*7", 42],
    ];

    console.log("\n--- Direct evaluation (_wasm_eval_arith) ---");
    let pass = 0;
    for (const [expr, expected] of testCases) {
        const vec = jsToWasmBytes(expr);
        try {
            const result = Number(ex['_wasm_eval_arith'](vec));
            const ok = result === expected;
            console.log(`  eval("${expr}") = ${result} — ${ok ? 'CORRECT ✓' : `WRONG (expected ${expected})`}`);
            if (ok) pass++;
        } catch (e) {
            console.log(`  eval("${expr}") TRAPPED: ${e.message}`);
        }
    }
    console.log(`\n=== RESULT: ${pass}/${testCases.length} CORRECT ===`);
}

main().catch(e => { console.error(e); process.exit(1); });
