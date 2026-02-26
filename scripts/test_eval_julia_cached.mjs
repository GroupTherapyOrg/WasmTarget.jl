// PURE-7006: Test eval_julia pipeline with pre-computed cached bytes
// Tests: diagnostic functions + full pipeline (parse → cached bytes → inner WASM → execute)
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-7006: Test eval_julia with cached WASM bytes ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
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

    // --- Test diagnostic functions ---
    console.log("--- Diagnostic functions ---");
    const diagTests = [
        ['_diag_stage0_len', '1+1', 3],
        ['_diag_stage0_ps', '1+1', 1],
        ['_diag_stage0_parse', '1+1', 2],
        ['_diag_stage0_cursor', '1+1', 3],
        ['_diag_stage1_parse', '1+1', 43],  // '+' = 43
        ['_diag_stage2_resolve', '1+1', 1],
        ['_diag_stage3a_world', '1+1', 1],
        ['_diag_stage3b_sig', '1+1', 2],
        ['_diag_stage3c_interp', '1+1', 3],  // PURE-7006: cached bytes
        ['_diag_stage3d_findall', '1+1', 4],  // PURE-7006: byte count
        ['_diag_stage3e_typeinf', '1+1', 5],  // PURE-7006: WASM magic
    ];

    let diagPass = 0;
    for (const [name, input, expected] of diagTests) {
        const vec = jsToWasmBytes(input);
        try {
            const fn = ex[name];
            if (!fn) {
                console.log(`  ${name}("${input}") = NOT EXPORTED`);
                continue;
            }
            const result = Number(fn(vec));
            const ok = result === expected;
            console.log(`  ${name}("${input}") = ${result} — ${ok ? 'CORRECT' : `WRONG (expected ${expected})`}`);
            if (ok) diagPass++;
        } catch (e) {
            console.log(`  ${name}("${input}") = TRAP: ${e.message}`);
        }
    }
    console.log(`  Diagnostics: ${diagPass}/${diagTests.length} CORRECT\n`);

    // --- Test eval_julia_to_bytes_vec ---
    console.log("--- eval_julia_to_bytes_vec ---");
    const pipelineTests = [
        ['1+1', '+', [1n, 1n], 2n],
        ['2+3', '+', [2n, 3n], 5n],
        ['10-3', '-', [10n, 3n], 7n],
        ['6*7', '*', [6n, 7n], 42n],
    ];

    let pipePass = 0;
    for (const [expr, opName, args, expected] of pipelineTests) {
        const vec = jsToWasmBytes(expr);
        try {
            const resultVec = ex['eval_julia_to_bytes_vec'](vec);
            const len = Number(ex['eval_julia_result_length'](resultVec));
            console.log(`  eval_julia_to_bytes_vec("${expr}") → ${len} bytes`);

            // Extract bytes from WasmGC Vector
            const innerBytes = new Uint8Array(len);
            for (let i = 0; i < len; i++) {
                innerBytes[i] = Number(ex['eval_julia_result_byte'](resultVec, i + 1));
            }

            // Verify WASM magic
            if (innerBytes[0] !== 0 || innerBytes[1] !== 0x61 ||
                innerBytes[2] !== 0x73 || innerBytes[3] !== 0x6d) {
                console.log(`    WRONG: not a valid WASM module (magic bytes mismatch)`);
                continue;
            }
            console.log(`    Valid WASM magic \\0asm`);

            // Instantiate the inner module
            const innerImports = { Math: { pow: Math.pow } };
            const inner = await WebAssembly.instantiate(innerBytes, innerImports);
            const innerFn = inner.instance.exports[opName];
            if (!innerFn) {
                console.log(`    WRONG: export "${opName}" not found`);
                continue;
            }

            // Call with operands and check result
            const result = innerFn(...args);
            const ok = result === expected;
            console.log(`    ${opName}(${args.join(', ')}) = ${result} — ${ok ? 'CORRECT ✓' : `WRONG (expected ${expected})`}`);
            if (ok) pipePass++;
        } catch (e) {
            console.log(`  eval_julia_to_bytes_vec("${expr}") = TRAP: ${e.message}`);
        }
    }

    console.log(`\n=== RESULT: Diagnostics ${diagPass}/${diagTests.length}, Pipeline ${pipePass}/${pipelineTests.length} ===`);
    if (diagPass === diagTests.length && pipePass === pipelineTests.length) {
        console.log("ALL CORRECT — eval_julia pipeline works end-to-end in WASM!");
    }
}

main().catch(e => { console.error(e); process.exit(1); });
