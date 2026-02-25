// PURE-6023: Test eval_julia("1+1") CORRECT in Node.js
// Ground truth: eval_julia_to_bytes_vec("1+1") should produce .wasm bytes
// that when instantiated execute to return 2.
//
// Native ground truth: eval_julia_native("1+1") = 2, "2+3" = 5, "10-3" = 7, "6*7" = 42

import { readFileSync } from 'fs';

async function main() {
    console.log("=== PURE-6023: Test eval_julia in Node.js ===\n");

    const wasmPath = '/tmp/eval_julia.wasm';
    const wasmBytes = readFileSync(wasmPath);
    console.log(`Module: ${wasmBytes.length} bytes`);

    const { instance } = await WebAssembly.instantiate(wasmBytes, {
        Math: { pow: Math.pow }
    });
    const ex = instance.exports;
    console.log(`INSTANTIATE SUCCESS (${Object.keys(ex).length} exports)\n`);

    // Helper: create WasmGC byte vec from JS string
    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    // Test the full pipeline
    const testCases = [
        ["1+1", 2],
        ["2+3", 5],
        ["10-3", 7],
        ["6*7", 42],
    ];

    let pass = 0;
    for (const [expr, expected] of testCases) {
        try {
            const vec = jsToWasmBytes(expr);
            console.log(`  eval_julia_to_bytes_vec("${expr}")...`);
            const result = ex['eval_julia_to_bytes_vec'](vec);

            // Get result bytes
            const len = Number(ex['eval_julia_result_length'](result));
            console.log(`    Returned ${len} bytes of .wasm`);

            if (len > 0 && len < 1000000) {
                const bytes = new Uint8Array(len);
                for (let i = 0; i < len; i++) {
                    bytes[i] = Number(ex['eval_julia_result_byte'](result, i + 1));
                }

                // Try to instantiate the generated WASM
                try {
                    const inner = await WebAssembly.instantiate(bytes);
                    const innerExports = Object.keys(inner.instance.exports);
                    console.log(`    Inner module exports: ${innerExports.join(', ')}`);

                    // Try to call the function (e.g., "+")
                    const fn = inner.instance.exports[innerExports[0]];
                    if (typeof fn === 'function') {
                        // For arithmetic, expect two Int64 (BigInt) args
                        const resultVal = Number(fn(BigInt(expected === 2 ? 1 : expr.charCodeAt(0) - 48),
                                                    BigInt(expected === 2 ? 1 : expr.charCodeAt(2) - 48)));
                        const ok = resultVal === expected;
                        console.log(`    Result: ${resultVal} — ${ok ? 'CORRECT ✓' : `WRONG (expected ${expected})`}`);
                        if (ok) pass++;
                    }
                } catch (e) {
                    console.log(`    Inner WASM error: ${e.message}`);
                }
            }
        } catch (e) {
            console.log(`  eval_julia_to_bytes_vec("${expr}") TRAPPED: ${e.message || e}`);
            // Identify which stubbed function caused the trap
            if (String(e).includes('unreachable')) {
                console.log(`    (Likely hit a stubbed/unsupported function)`);
            }
        }
        console.log();
    }

    console.log(`=== RESULT: ${pass}/${testCases.length} CORRECT ===`);
    if (pass === testCases.length) {
        console.log("ALL CORRECT — eval_julia_to_bytes_vec works end-to-end in WASM!");
    } else {
        console.log(`${testCases.length - pass} failures`);
    }
}

main().catch(e => { console.error(e); process.exit(1); });
