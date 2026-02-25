// PURE-6023: Test eval_julia("1+1") CORRECT in Node.js
// Tests both paths:
//   Path A: _wasm_eval_arith — direct evaluation (REAL JuliaSyntax + Julia operators)
//   Path B: eval_julia_to_bytes_vec — codegen-in-WASM (blocked by dead code guard cascade)
//
// Native ground truth: eval_julia_native("1+1") = 2, "2+3" = 5, "10-3" = 7, "6*7" = 42

import { readFileSync, existsSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-6023: Test eval_julia in Node.js ===\n");

    // ====================================================================
    // Path A: Direct evaluation via _wasm_eval_arith (REAL parser + operators)
    // ====================================================================
    const arithPath = join(__dirname, '..', 'output', 'eval_julia_arith.wasm');
    if (!existsSync(arithPath)) {
        console.log("ERROR: output/eval_julia_arith.wasm not found");
        process.exit(1);
    }

    const arithBytes = readFileSync(arithPath);
    console.log(`[Path A: Direct Evaluation]`);
    console.log(`Module: ${arithBytes.length} bytes (${(arithBytes.length/1024/1024).toFixed(1)} MB)`);

    const { instance: arithInst } = await WebAssembly.instantiate(arithBytes, {
        Math: { pow: Math.pow }
    });
    const arith = arithInst.exports;
    const funcExports = Object.keys(arith).filter(k => typeof arith[k] === 'function');
    console.log(`INSTANTIATE SUCCESS (${funcExports.length} func exports)\n`);

    // Helper: create WasmGC byte vec from JS string
    function jsToWasmBytes(ex, str) {
        const bytes = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    // Test 4 ground truth expressions
    const testCases = [
        ["1+1", 2],
        ["2+3", 5],
        ["10-3", 7],
        ["6*7", 42],
    ];

    console.log("--- Direct evaluation (_wasm_eval_arith) ---");
    console.log("  Uses REAL JuliaSyntax parser + Julia operators in WASM\n");

    let pass = 0;
    for (const [expr, expected] of testCases) {
        const vec = jsToWasmBytes(arith, expr);
        try {
            const result = Number(arith['_wasm_eval_arith'](vec));
            const ok = result === expected;
            console.log(`  eval("${expr}") = ${result} — ${ok ? 'CORRECT ✓' : `WRONG (expected ${expected})`}`);
            if (ok) pass++;
        } catch (e) {
            console.log(`  eval("${expr}") TRAPPED: ${e.message}`);
        }
    }

    console.log(`\n=== Path A RESULT: ${pass}/${testCases.length} CORRECT ===`);
    if (pass === testCases.length) {
        console.log("ALL CORRECT — eval_julia works in WASM (direct evaluation path)!");
    }
    console.log();

    // ====================================================================
    // Path B: Codegen-in-WASM via eval_julia_to_bytes_vec
    // (Currently blocked by dead code guard cascade — PURE-6027)
    // ====================================================================
    const pipelinePath = '/tmp/eval_julia.wasm';
    if (existsSync(pipelinePath)) {
        console.log(`[Path B: Codegen-in-WASM (integration module)]`);
        const pipelineBytes = readFileSync(pipelinePath);
        console.log(`Module: ${pipelineBytes.length} bytes (${(pipelineBytes.length/1024/1024).toFixed(1)} MB)`);

        try {
            const { instance: pipeInst } = await WebAssembly.instantiate(pipelineBytes, {
                Math: { pow: Math.pow }
            });
            const pipe = pipeInst.exports;
            const pipeExports = Object.keys(pipe).filter(k => typeof pipe[k] === 'function');
            console.log(`INSTANTIATE SUCCESS (${pipeExports.length} func exports)\n`);

            console.log("--- Codegen pipeline (eval_julia_to_bytes_vec) ---");
            console.log("  NOTE: Currently blocked by dead code guard cascade (PURE-6027)\n");

            let pipePass = 0;
            for (const [expr, expected] of testCases) {
                const vec = jsToWasmBytes(pipe, expr);
                try {
                    const result = pipe['eval_julia_to_bytes_vec'](vec);
                    const len = Number(pipe['eval_julia_result_length'](result));
                    console.log(`  eval_julia_to_bytes_vec("${expr}") → ${len} bytes`);

                    if (len > 0 && len < 1000000) {
                        const bytes = new Uint8Array(len);
                        for (let i = 0; i < len; i++) {
                            bytes[i] = Number(pipe['eval_julia_result_byte'](result, i + 1));
                        }
                        const inner = await WebAssembly.instantiate(bytes);
                        const innerExports = Object.keys(inner.instance.exports);
                        const fn = inner.instance.exports[innerExports[0]];
                        if (typeof fn === 'function') {
                            // Parse args from expression for BigInt
                            const parts = expr.match(/(\d+)([+\-*])(\d+)/);
                            const resultVal = Number(fn(BigInt(parseInt(parts[1])),
                                                       BigInt(parseInt(parts[3]))));
                            const ok = resultVal === expected;
                            console.log(`    Result: ${resultVal} — ${ok ? 'CORRECT ✓' : `WRONG (expected ${expected})`}`);
                            if (ok) pipePass++;
                        }
                    }
                } catch (e) {
                    console.log(`  eval_julia_to_bytes_vec("${expr}") TRAPPED: ${e.message}`);
                    if (String(e).includes('unreachable')) {
                        console.log(`    (Dead code guard cascade — see PURE-6027)`);
                    }
                }
            }

            console.log(`\n=== Path B RESULT: ${pipePass}/${testCases.length} CORRECT ===`);
            if (pipePass < testCases.length) {
                console.log(`Codegen path blocked — ${testCases.length - pipePass} traps (PURE-6027)`);
            }
        } catch (e) {
            console.log(`Path B: Could not instantiate — ${e.message}`);
        }
    } else {
        console.log("[Path B: Codegen-in-WASM — skipped (no /tmp/eval_julia.wasm)]");
    }

    // Final summary
    console.log("\n=== SUMMARY ===");
    console.log(`Path A (direct evaluation): ${pass}/${testCases.length} CORRECT`);
    console.log(`Path B (codegen-in-WASM):   blocked by dead code guard (PURE-6027)`);
    console.log(`\nFor browser integration (PURE-6008): use Path A (output/eval_julia_arith.wasm)`);
}

main().catch(e => { console.error(e); process.exit(1); });
