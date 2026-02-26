// PURE-7011: EXPAND test — arithmetic expansion: "2*3", "10-3", "6*7", "2.0+3.0"
// Tests both Int64 and Float64 arithmetic paths through the real eval_julia pipeline.
//
// Int64 expressions produce 96-byte inner modules with (i64, i64) → i64 functions.
// Float64 expressions produce 90-byte inner modules with (f64, f64) → f64 functions.
// JS must pass BigInt for i64 and Number for f64 params.

import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

function jsToWasmBytes(ex, str) {
    const vec = ex['make_byte_vec'](str.length);
    for (let i = 0; i < str.length; i++) {
        ex['set_byte_vec!'](vec, i + 1, str.charCodeAt(i));
    }
    return vec;
}

function wasmBytesToJS(ex, wasmVec) {
    const len = ex['eval_julia_result_length'](wasmVec);
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
        bytes[i] = ex['eval_julia_result_byte'](wasmVec, i + 1);
    }
    return bytes;
}

// Detect if expression uses float operands (contains '.')
function isFloatExpr(expr) {
    return expr.includes('.');
}

async function main() {
    console.log("=== PURE-7011: EXPAND — Arithmetic expansion test ===\n");

    // Load outer module
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    console.log(`Outer module: ${wasmBytes.length} bytes`);

    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const ex = instance.exports;
    const fnCount = Object.keys(ex).filter(k => typeof ex[k] === 'function').length;
    console.log(`Exports: ${fnCount} functions\n`);

    // Test cases — native Julia ground truth:
    //   2*3   → 6   (Int64 multiplication)
    //   10-3  → 7   (Int64 multi-digit subtraction)
    //   6*7   → 42  (Int64 multiplication)
    //   2.0+3.0 → 5.0 (Float64 addition — new type path)
    //
    // Also re-verify existing gate cases:
    //   1+1   → 2   (Int64 addition)
    //   2+3   → 5   (Int64 addition)
    const testCases = [
        // Existing gate (verify no regression)
        { expr: "1+1",     expected: 2,   type: "Int64",   op: "+" },
        { expr: "2+3",     expected: 5,   type: "Int64",   op: "+" },
        // PURE-7011 new expressions
        { expr: "2*3",     expected: 6,   type: "Int64",   op: "*" },
        { expr: "10-3",    expected: 7,   type: "Int64",   op: "-" },
        { expr: "6*7",     expected: 42,  type: "Int64",   op: "*" },
        { expr: "2.0+3.0", expected: 5.0, type: "Float64", op: "+" },
    ];

    let pass = 0;
    let fail = 0;
    const results = [];

    for (const { expr, expected, type: valType, op } of testCases) {
        const label = `eval_julia("${expr}")`;
        try {
            // Step 1: Call eval_julia_to_bytes_vec in WASM
            const inputVec = jsToWasmBytes(ex, expr);
            const resultVec = ex['eval_julia_to_bytes_vec'](inputVec);

            // Step 2: Extract inner WASM bytes
            const innerBytes = wasmBytesToJS(ex, resultVec);

            // Step 3: Validate inner module magic number
            if (innerBytes[0] !== 0x00 || innerBytes[1] !== 0x61 ||
                innerBytes[2] !== 0x73 || innerBytes[3] !== 0x6d) {
                throw new Error(`Invalid WASM magic: ${Array.from(innerBytes.slice(0, 4)).map(b => '0x' + b.toString(16)).join(' ')}`);
            }

            // Step 4: Instantiate inner module
            const inner = await WebAssembly.instantiate(innerBytes, imports);
            const fn = inner.instance.exports[op];
            if (!fn) {
                throw new Error(`No export "${op}" in inner module (has: ${Object.keys(inner.instance.exports).join(', ')})`);
            }

            // Step 5: Parse operands and call with correct types
            const parts = expr.split(/([+\-*/])/);
            const isFloat = isFloatExpr(expr);
            let result;

            if (isFloat) {
                // Float64 path: pass JS Numbers (f64)
                const left = parseFloat(parts[0]);
                const right = parseFloat(parts[2]);
                result = fn(left, right);
            } else {
                // Int64 path: pass BigInt
                const left = BigInt(parseInt(parts[0], 10));
                const right = BigInt(parseInt(parts[2], 10));
                result = fn(left, right);
            }

            const resultNum = Number(result);

            if (resultNum === expected) {
                console.log(`  ${label} = ${resultNum} — CORRECT [${valType}, ${innerBytes.length} byte inner module]`);
                pass++;
                results.push({ expr, status: 'CORRECT', value: resultNum });
            } else {
                console.log(`  ${label} = ${resultNum} — WRONG (expected ${expected}) [${valType}]`);
                fail++;
                results.push({ expr, status: 'WRONG', value: resultNum, expected });
            }
        } catch (e) {
            console.log(`  ${label} = ERROR: ${e.message}`);
            fail++;
            results.push({ expr, status: 'ERROR', error: e.message });
        }
    }

    console.log(`\n=== RESULT: ${pass}/${testCases.length} CORRECT ===`);

    if (pass === testCases.length) {
        console.log("ALL CORRECT — Int64 and Float64 arithmetic verified!");
        console.log("M_PORT_EXPAND arithmetic: PASS");
    } else {
        console.log(`${fail} failure(s):`);
        for (const r of results) {
            if (r.status !== 'CORRECT') {
                console.log(`  "${r.expr}": ${r.status}${r.error ? ' — ' + r.error : ''}`);
            }
        }
        process.exit(1);
    }
}

main().catch(e => { console.error(e); process.exit(1); });
