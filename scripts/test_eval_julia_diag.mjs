// PURE-6024 Agent 26: Detailed diagnostic test for eval_julia.wasm
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-6024 Agent 26: Detailed eval_julia diagnostic ===\n");

    // Load module
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    console.log(`File size: ${wasmBytes.length} bytes`);

    const imports = { Math: { pow: Math.pow } };
    const result = await WebAssembly.instantiate(wasmBytes, imports);
    const E = result.instance.exports;

    const funcExports = Object.keys(E).filter(k => typeof E[k] === 'function');
    console.log(`Function exports: ${funcExports.length}`);

    // List all exports containing "eval_julia" or "node" or "build" or "leaf" or "untokenize"
    const diagnosticExports = funcExports.filter(k =>
        k.includes('eval_julia') || k.includes('node_step') || k.includes('build_tree') ||
        k.includes('leaf') || k.includes('untokenize') || k.includes('parse') ||
        k.includes('make_byte') || k.includes('set_byte')
    );
    console.log(`\nDiagnostic exports (${diagnosticExports.length}):`);
    for (const name of diagnosticExports.sort()) {
        console.log(`  ${name}`);
    }

    // Helper to create byte vectors
    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = E['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            E['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    // Test helper: run a function with error details
    function safeCall(name, ...args) {
        try {
            const fn = E[name];
            if (!fn) return { status: 'MISSING', value: null };
            const val = fn(...args);
            return { status: 'OK', value: val };
        } catch (e) {
            if (e instanceof WebAssembly.Exception) {
                return { status: 'WASM_EXCEPTION', value: e.toString() };
            } else if (e instanceof WebAssembly.RuntimeError) {
                return { status: 'RUNTIME_ERROR', value: e.message };
            } else {
                return { status: 'JS_ERROR', value: e.message || String(e) };
            }
        }
    }

    // Test basic diagnostics first (these should work per Agent 22)
    console.log("\n--- Basic diagnostics (with fresh byte vec per call) ---");
    const basicTests = [
        ['make_byte_vec', [3]],
    ];

    const vec3 = jsToWasmBytes("1+1");
    console.log(`  make_byte_vec(3) + set: OK (created "1+1" byte vec)`);

    // Test the diagnostic functions that were passing for Agent 22
    const diagTests = [
        'eval_julia_test_input_len',
        'eval_julia_test_array_nvals',
        'eval_julia_test_textbuf',
        'eval_julia_test_ps_create',
        'eval_julia_test_parse_only',
        'eval_julia_test_child_count',
        'eval_julia_test_kind_string',
        'eval_julia_test_tree_nranges',
        'eval_julia_test_is_error',
        'eval_julia_test_build_tree',
        'eval_julia_test_parse_int',
        'eval_julia_test_string_from_bytes',
        'eval_julia_test_wasm_leaf',
        'eval_julia_test_node_to_expr',
        'eval_julia_test_node_steps',
    ];

    for (const name of diagTests) {
        if (!E[name]) continue;
        // Create a FRESH byte vec for each test (Agent 22 learned: String() empties the vector)
        const freshVec = jsToWasmBytes("1+1");
        const r = safeCall(name, freshVec);
        console.log(`  ${name}: ${r.status} → ${r.value}`);
    }

    // Test the full pipeline
    console.log("\n--- Full pipeline: eval_julia_to_bytes_vec ---");
    for (const expr of ["1+1", "2+3", "10-3", "6*7"]) {
        const freshVec = jsToWasmBytes(expr);
        const r = safeCall('eval_julia_to_bytes_vec', freshVec);
        console.log(`  eval_julia_to_bytes_vec("${expr}"): ${r.status} → ${r.value}`);

        if (r.status === 'OK' && r.value != null) {
            const len = safeCall('eval_julia_result_length', r.value);
            console.log(`    result_length: ${len.status} → ${len.value}`);
            if (len.status === 'OK' && len.value > 0) {
                // Check first 8 bytes
                const firstBytes = [];
                for (let i = 1; i <= Math.min(len.value, 8); i++) {
                    const b = safeCall('eval_julia_result_byte', r.value, i);
                    firstBytes.push(b.value);
                }
                console.log(`    first bytes: ${firstBytes.map(b => '0x' + Number(b).toString(16).padStart(2,'0')).join(' ')}`);
            }
        }
    }

    console.log("\n=== Done ===");
}

main().catch(e => { console.error(e); process.exit(1); });
