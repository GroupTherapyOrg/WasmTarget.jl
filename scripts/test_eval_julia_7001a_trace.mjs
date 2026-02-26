// PURE-7001a: Get trap stack trace from _diag_stage1_parse (after dead code guard fix)
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-7001a: Trap Stack Trace After Fix ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);

    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const ex = instance.exports;

    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    // Confirm new passes
    console.log("--- Confirmed fixes ---");
    for (const [name, expected] of [
        ['_diag_stage0_parse', 2],
        ['_diag_stage0_cursor', 3]
    ]) {
        try {
            const v = jsToWasmBytes("1+1");
            const r = ex[name](v);
            console.log(`  ${name}: ${Number(r)} — ${Number(r) === expected ? 'CORRECT' : 'WRONG'}`);
        } catch (e) {
            console.log(`  ${name}: TRAP — ${e.message}`);
        }
    }

    // Get trace from _diag_stage1_parse
    console.log("\n--- _diag_stage1_parse trap trace ---");
    try {
        const v = jsToWasmBytes("1+1");
        const r = ex['_diag_stage1_parse'](v);
        console.log(`  Result: ${r} — UNEXPECTED PASS!`);
    } catch (e) {
        console.log(`  TRAP: ${e.message}`);
        if (e.stack) {
            console.log("\n  Stack trace:");
            for (const line of e.stack.split('\n')) {
                console.log(`    ${line}`);
            }
        }
    }

    // Get trace from eval_julia_to_bytes_vec
    console.log("\n--- eval_julia_to_bytes_vec trap trace ---");
    try {
        const v = jsToWasmBytes("1+1");
        const r = ex['eval_julia_to_bytes_vec'](v);
        console.log(`  Result: ${r} — UNEXPECTED PASS!`);
    } catch (e) {
        console.log(`  TRAP: ${e.message}`);
        if (e.stack) {
            console.log("\n  Stack trace:");
            for (const line of e.stack.split('\n').slice(0, 15)) {
                console.log(`    ${line}`);
            }
        }
    }

    console.log("\n=== Done ===");
}

main().catch(e => { console.error(e); process.exit(1); });
