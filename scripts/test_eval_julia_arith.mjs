// Test _wasm_eval_arith — direct evaluation of arithmetic in WASM
// Ground truth: must match native Julia output exactly
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-6026: Test _wasm_eval_arith in WASM ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia_arith.wasm');
    const wasmBytes = await readFile(wasmPath);
    console.log(`File size: ${wasmBytes.length} bytes`);

    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const ex = instance.exports;

    // List function exports
    const funcExports = Object.keys(ex).filter(k => typeof ex[k] === 'function');
    console.log(`Function exports: ${funcExports.length}`);
    console.log();

    // Helper: create WasmGC byte vec from JS string
    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    // Test 1: Parse diagnostics (already CORRECT from Agent 27)
    console.log("--- Parse diagnostics ---");
    const testCases = [
        ["1+1", 43001001],
        ["2+3", 43002003],
        ["6*7", 42006007],
        ["9-3", 45009003],
    ];

    let parsePass = 0;
    for (const [expr, expected] of testCases) {
        const vec = jsToWasmBytes(expr);
        try {
            const result = ex['eval_julia_test_parse_arith'](vec);
            const ok = result === expected;
            console.log(`  parse("${expr}") = ${result} — ${ok ? 'CORRECT' : `WRONG (expected ${expected})`}`);
            if (ok) parsePass++;
        } catch (e) {
            console.log(`  parse("${expr}") = ERROR: ${e.message}`);
        }
    }
    console.log(`  Parse: ${parsePass}/${testCases.length} CORRECT\n`);

    // Test 2: Direct evaluation — THE MAIN TEST
    console.log("--- Direct evaluation (_wasm_eval_arith) ---");
    const evalCases = [
        ["1+1", 2],
        ["2+3", 5],
        ["9-3", 6],
        ["6*7", 42],
        ["3+4", 7],
        ["8-2", 6],
        ["5*9", 45],
    ];

    let evalPass = 0;
    for (const [expr, expected] of evalCases) {
        const vec = jsToWasmBytes(expr);
        try {
            // _wasm_eval_arith returns Int64 (BigInt in JS)
            const result = ex['_wasm_eval_arith'](vec);
            const resultNum = Number(result);
            const ok = resultNum === expected;
            console.log(`  eval("${expr}") = ${resultNum} — ${ok ? 'CORRECT ✓' : `WRONG (expected ${expected})`}`);
            if (ok) evalPass++;
        } catch (e) {
            console.log(`  eval("${expr}") = ERROR: ${e.message}`);
            // Try the Int32 diagnostic wrapper
            try {
                const result32 = ex['eval_julia_test_eval_arith'](vec);
                console.log(`    diagnostic: eval_julia_test_eval_arith = ${result32}`);
            } catch (e2) {
                console.log(`    diagnostic also failed: ${e2.message}`);
            }
        }
    }

    console.log(`\n=== RESULT: ${evalPass}/${evalCases.length} CORRECT ===`);
    if (evalPass === evalCases.length) {
        console.log("ALL CORRECT — _wasm_eval_arith works in WASM!");
    } else {
        console.log(`${evalCases.length - evalPass} failures — investigate`);
    }
}

main().catch(e => { console.error(e); process.exit(1); });
