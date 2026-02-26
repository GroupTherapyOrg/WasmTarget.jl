// PURE-8000: Test runtime stages 3-4 in WASM
// Goal: enumerate ALL traps when calling eval_julia_to_bytes_vec("1+1")
// The runtime compile function _wasm_runtime_compile_plus_i64 should now be
// in the WASM module (added to seed). This test documents every trap.
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-8000: Test runtime stages 3-4 in WASM ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    console.log(`File size: ${wasmBytes.length} bytes`);

    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const ex = instance.exports;

    // List function exports
    const funcExports = Object.keys(ex).filter(k => typeof ex[k] === 'function');
    console.log(`Function exports: ${funcExports.length}`);

    // Check if runtime compile function is exported
    const runtimeFuncs = funcExports.filter(k => k.includes('runtime_compile'));
    console.log(`Runtime compile exports: ${runtimeFuncs.length}`);
    for (const f of runtimeFuncs) {
        console.log(`  - ${f}`);
    }
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

    // Test 1: Diagnostics (stages 0-2 should still work)
    console.log("--- Stage 0-2 diagnostics (should still work) ---");
    const diagTests = [
        ['_diag_stage0_len', '1+1', 3],
        ['_diag_stage0_ps', '1+1', 1],
        ['_diag_stage0_parse', '1+1', 2],
        ['_diag_stage0_cursor', '1+1', 3],
        ['_diag_stage1_parse', '1+1', null],
        ['_diag_stage2_resolve', '1+1', null],
    ];

    for (const [fn, input, expected] of diagTests) {
        const vec = jsToWasmBytes(input);
        try {
            const result = ex[fn](vec);
            const status = expected !== null ? (Number(result) === expected ? 'CORRECT' : `WRONG (expected ${expected})`) : `= ${result}`;
            console.log(`  ${fn}("${input}") ${status}`);
        } catch (e) {
            console.log(`  ${fn}("${input}") TRAP: ${e.message}`);
        }
    }
    console.log();

    // Test 2: Stage 3 diagnostics
    console.log("--- Stage 3 diagnostics ---");
    const stage3Tests = [
        '_diag_stage3a_world',
        '_diag_stage3b_sig',
        '_diag_stage3c_interp',
        '_diag_stage3d_findall',
        '_diag_stage3e_typeinf',
    ];

    for (const fn of stage3Tests) {
        const vec = jsToWasmBytes('1+1');
        try {
            const result = ex[fn](vec);
            console.log(`  ${fn}("1+1") = ${result}`);
        } catch (e) {
            console.log(`  ${fn}("1+1") TRAP: ${e.message}`);
        }
    }
    console.log();

    // Test 3: Direct call to _wasm_runtime_compile_plus_i64 (if exported)
    console.log("--- Runtime compile function (direct call) ---");
    if (ex['_wasm_runtime_compile_plus_i64']) {
        try {
            const result = ex['_wasm_runtime_compile_plus_i64']();
            console.log(`  _wasm_runtime_compile_plus_i64() = ${result} (type: ${typeof result})`);
            // If it returns a vec, try to read length
            if (result && ex['eval_julia_result_length']) {
                try {
                    const len = ex['eval_julia_result_length'](result);
                    console.log(`  Result length: ${len} bytes`);
                } catch (e2) {
                    console.log(`  Result length: ERROR: ${e2.message}`);
                }
            }
        } catch (e) {
            console.log(`  _wasm_runtime_compile_plus_i64() TRAP: ${e.message}`);
        }
    } else {
        console.log(`  _wasm_runtime_compile_plus_i64 NOT EXPORTED`);
    }
    console.log();

    // Test 4: Full pipeline eval_julia_to_bytes_vec("1+1")
    console.log("--- Full pipeline: eval_julia_to_bytes_vec ---");
    const vec = jsToWasmBytes('1+1');
    try {
        const result = ex['eval_julia_to_bytes_vec'](vec);
        console.log(`  eval_julia_to_bytes_vec("1+1") returned (type: ${typeof result})`);
        if (result && ex['eval_julia_result_length']) {
            const len = ex['eval_julia_result_length'](result);
            console.log(`  Result length: ${len} bytes`);
            console.log(`  SUCCESS — runtime stages 3-4 produced WASM bytes!`);
        }
    } catch (e) {
        console.log(`  eval_julia_to_bytes_vec("1+1") TRAP: ${e.message}`);
    }

    console.log("\n=== PURE-8000 DISCOVERY COMPLETE ===");
}

main().catch(e => { console.error(e); process.exit(1); });
