// PURE-7002: Test _diag_binop_* sub-diagnostics to isolate array access trap
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-7002: Binop Sub-Diagnostics ===\n");

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

    // Test each binop sub-diagnostic
    const tests = [
        ['_diag_binop_a_fields', 'root cursor fields (position)', 'expect 5 for "1+1"'],
        ['_diag_binop_b_rootraw', 'root raw node (node_span)', 'expect 3 for "1+1"'],
        ['_diag_binop_c_child1', 'first child (byte_span)', 'expect 1 for "1" token'],
        ['_diag_binop_d_child2', 'second child (byte_span)', 'expect 1 for "+" token'],
        ['_diag_binop_e_txtaccess', 'txtbuf[byte_end]', 'expect 49 (\'1\' = 0x31)'],
        ['_diag_binop_f_full', 'full _wasm_binop_byte_starts', 'expect 2 for op_start'],
    ];

    // Also test stage1 sub-diagnostics
    const stage1tests = [
        ['_diag_stage1a_textbuf', 'get textbuf length'],
        ['_diag_stage1b_children', 'get children iterator'],
        ['_diag_stage1c_iterate', 'first iterate call'],
        ['_diag_stage1d_getindex', 'access first element'],
        ['_diag_stage1e_byterange', 'byte_end field access'],
        ['_diag_stage1f_span', 'green position field'],
        ['_diag_stage1g_rawnode', 'parser_output[position]'],
        ['_diag_stage1h_iter2', 'second iterate call'],
        ['_diag_stage1i_byterange_call', 'byte_range on child1'],
        ['_diag_stage1j_root_byterange', 'byte_range on root'],
    ];

    console.log("--- Binop flat traversal diagnostics ---");
    for (const [fname, desc, expect] of tests) {
        try {
            const v = jsToWasmBytes("1+1");
            const fn = ex[fname];
            if (!fn) { console.log(`  MISSING: ${fname}`); continue; }
            const r = fn(v);
            console.log(`  PASS: ${fname} = ${Number(r)} — ${desc} (${expect})`);
        } catch (e) {
            console.log(`  TRAP: ${fname} — ${e.message} — ${desc}`);
        }
    }

    console.log("\n--- Stage 1 sub-diagnostics (iterate-based) ---");
    for (const [fname, desc] of stage1tests) {
        try {
            const v = jsToWasmBytes("1+1");
            const fn = ex[fname];
            if (!fn) { console.log(`  MISSING: ${fname}`); continue; }
            const r = fn(v);
            console.log(`  PASS: ${fname} = ${Number(r)} — ${desc}`);
        } catch (e) {
            console.log(`  TRAP: ${fname} — ${e.message} — ${desc}`);
        }
    }

    // Also test _diag_stage1_parse directly for the stack trace
    console.log("\n--- _diag_stage1_parse trap trace ---");
    try {
        const v = jsToWasmBytes("1+1");
        const r = ex['_diag_stage1_parse'](v);
        console.log(`  PASS: _diag_stage1_parse = ${Number(r)}`);
    } catch (e) {
        console.log(`  TRAP: ${e.message}`);
        if (e.stack) {
            const lines = e.stack.split('\n').slice(0, 20);
            for (const line of lines) {
                console.log(`    ${line}`);
            }
        }
    }

    console.log("\n=== Done ===");
}

main().catch(e => { console.error(e); process.exit(1); });
