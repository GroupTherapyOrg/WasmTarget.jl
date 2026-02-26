// PURE-7001 Agent 3: Get trap stack trace from _diag_stage0_parse
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-7001: Trap Stack Trace ===\n");

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

    // Test 1: Confirm _diag_stage0_ps works
    console.log("--- _diag_stage0_ps (expected: PASS) ---");
    try {
        const v = jsToWasmBytes("1+1");
        const r = ex['_diag_stage0_ps'](v);
        console.log(`  Result: ${r} — ${Number(r) === 1 ? 'CORRECT' : 'WRONG'}`);
    } catch (e) {
        console.log(`  TRAP: ${e.message}`);
    }

    // Test 2: Get stack trace from _diag_stage0_parse trap
    console.log("\n--- _diag_stage0_parse (expected: TRAP) ---");
    try {
        const v = jsToWasmBytes("1+1");
        const r = ex['_diag_stage0_parse'](v);
        console.log(`  Result: ${r} — UNEXPECTED PASS!`);
    } catch (e) {
        console.log(`  TRAP: ${e.message}`);
        if (e.stack) {
            console.log("\n  Full stack trace:");
            const lines = e.stack.split('\n');
            for (const line of lines) {
                console.log(`    ${line}`);
            }
        }
    }

    // Test 3: Get function index from trap
    // The stack trace shows wasm function indices like "wasm-function[123]"
    // We can map those to export names

    console.log("\n--- Export name → function index mapping (first 50) ---");
    // Print the WAT export lines to help map func indices
    const wasmText = await readFile(wasmPath);
    // Can't easily parse binary WASM in JS, but the stack trace indices help

    // Test 4: Try calling _wasm_parse_statement! via a new diag wrapper
    console.log("\n--- Direct _wasm_parse_statement! call (via diag wrapper) ---");
    // _diag_stage0_parse calls _wasm_parse_statement!(ps), which calls:
    //   ParseState(ps) → parse_stmts(pstate) → validate_tokens(ps)
    // We can't easily split these from JS, but the stack trace should show the chain.

    console.log("\n=== Done ===");
}

main().catch(e => { console.error(e); process.exit(1); });
