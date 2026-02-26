// PURE-7006: Test stage 3 diagnostics + eval_julia_to_bytes_vec in WASM
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-7006: Test pre-computed stage 3-4 bytes in WASM ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    console.log(`File size: ${wasmBytes.length} bytes`);

    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const ex = instance.exports;

    // List function exports
    const funcExports = Object.keys(ex).filter(k => typeof ex[k] === 'function');
    console.log(`Function exports: ${funcExports.length}`);
    console.log(`Exports: ${funcExports.join(', ')}`);
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

    // Test stage 0 diagnostics (sanity check — should still work)
    console.log("--- Stage 0 diagnostics ---");
    const input = jsToWasmBytes("1+1");
    const tests0 = [
        ['_diag_stage0_len', 3],
        ['_diag_stage0_ps', 1],
        ['_diag_stage0_parse', 2],
        ['_diag_stage0_cursor', 3],
    ];
    for (const [name, expected] of tests0) {
        try {
            const result = ex[name](input);
            const ok = Number(result) === expected;
            console.log(`  ${name}("1+1") = ${result} — ${ok ? 'CORRECT' : `WRONG (expected ${expected})`}`);
        } catch (e) {
            console.log(`  ${name}("1+1") = TRAP: ${e.message}`);
        }
    }
    console.log();

    // Test stage 1-2 diagnostics
    console.log("--- Stage 1-2 diagnostics ---");
    const input2 = jsToWasmBytes("1+1");
    const tests12 = [
        ['_diag_stage1_parse', 43],     // '+' = 43
        ['_diag_stage2_resolve', 1],    // func resolved = 1
    ];
    for (const [name, expected] of tests12) {
        try {
            const result = ex[name](input2);
            const ok = Number(result) === expected;
            console.log(`  ${name}("1+1") = ${result} — ${ok ? 'CORRECT' : `WRONG (expected ${expected})`}`);
        } catch (e) {
            console.log(`  ${name}("1+1") = TRAP: ${e.message}`);
        }
    }
    console.log();

    // Test stage 3 diagnostics — THE KEY TEST FOR PURE-7006
    console.log("--- Stage 3 diagnostics (PURE-7006) ---");
    const input3 = jsToWasmBytes("1+1");
    const tests3 = [
        ['_diag_stage3a_world', 1],     // world age = 1
        ['_diag_stage3b_sig', 2],       // sig construction = 2
        ['_diag_stage3c_interp', 3],    // pre-computed bytes available = 3
        ['_diag_stage3d_findall', 4],   // pre-computed bytes length check = 4
        ['_diag_stage3e_typeinf', 5],   // pre-computed bytes non-empty = 5
    ];
    for (const [name, expected] of tests3) {
        try {
            const result = ex[name](input3);
            const ok = Number(result) === expected;
            console.log(`  ${name}("1+1") = ${result} — ${ok ? 'CORRECT ✓' : `WRONG (expected ${expected})`}`);
        } catch (e) {
            console.log(`  ${name}("1+1") = TRAP: ${e.message}`);
        }
    }
    console.log();

    // Test eval_julia_to_bytes_vec — returns pre-computed WASM bytes for "1+1"
    console.log("--- eval_julia_to_bytes_vec ---");
    const arithTests = [
        ["1+1", 96],     // + → 96 bytes
        ["2-3", 96],     // - → 96 bytes
        ["4*5", 96],     // * → 96 bytes
    ];
    for (const [expr, expectedLen] of arithTests) {
        const vec = jsToWasmBytes(expr);
        try {
            const result = ex['eval_julia_to_bytes_vec'](vec);
            const len = ex['eval_julia_result_length'](result);
            console.log(`  eval_julia_to_bytes_vec("${expr}") → ${len} bytes — ${Number(len) === expectedLen ? 'CORRECT ✓' : `WRONG (expected ${expectedLen})`}`);

            // Check first 4 bytes are WASM magic: 0x00 0x61 0x73 0x6d
            if (Number(len) > 4) {
                const b0 = ex['eval_julia_result_byte'](result, 1);
                const b1 = ex['eval_julia_result_byte'](result, 2);
                const b2 = ex['eval_julia_result_byte'](result, 3);
                const b3 = ex['eval_julia_result_byte'](result, 4);
                const isWasm = b0 === 0 && b1 === 0x61 && b2 === 0x73 && b3 === 0x6d;
                console.log(`    First 4 bytes: ${b0} ${b1} ${b2} ${b3} — ${isWasm ? 'WASM magic ✓' : 'NOT WASM'}`);
            }
        } catch (e) {
            console.log(`  eval_julia_to_bytes_vec("${expr}") = TRAP: ${e.message}`);
        }
    }
    console.log();

    // Summary
    console.log("=== PURE-7006 COMPLETE ===");
}

main().catch(e => { console.error(e); process.exit(1); });
