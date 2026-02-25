// Diagnostic test for minimal eval_julia.wasm — test each stage individually
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== Minimal eval_julia.wasm Diagnostic Test ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    console.log(`File size: ${wasmBytes.length} bytes`);

    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const ex = instance.exports;

    // List all function exports
    const funcExports = Object.keys(ex).filter(k => typeof ex[k] === 'function');
    console.log(`Function exports: ${funcExports.length}`);
    console.log(`Exports: ${funcExports.sort().join(', ')}\n`);

    // Helper: create WasmGC byte vec from JS string
    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    const testInput = "1+1";
    const inputVec = jsToWasmBytes(testInput);
    console.log(`Input: "${testInput}" → WasmGC vec created\n`);

    // Test diagnostics one by one
    const tests = [
        ['eval_julia_test_input_len', inputVec, 'should return 3 (byte length of "1+1")'],
        ['eval_julia_test_ps_create', inputVec, 'should return 1 (ParseStream created)'],
        ['eval_julia_test_parse_only', inputVec, 'should return 1 (parse! succeeded)'],
        ['eval_julia_test_build_tree_wasm', inputVec, 'should return 3 (_wasm_build_tree_expr: Expr(:call))'],
        ['eval_julia_test_simple_call', inputVec, 'should return 3 (3 args in Expr(:call)) — uses OLD for-loop version'],
        ['eval_julia_test_simple_call_steps', inputVec, 'steps: neg=fail step, 5379=success ("1+1")'],
        ['eval_julia_test_flat_call', inputVec, 'should return 3 (flat version, no phi nodes)'],
        ['eval_julia_test_parse_arith', inputVec, 'should return 43001001 (op=43 +, left=1, right=1)'],
        ['_wasm_simple_call_expr', null, '(skip - needs ParseStream ref)'],
    ];

    let passCount = 0;
    let failCount = 0;
    for (const [name, arg, desc] of tests) {
        if (!ex[name]) {
            console.log(`  ${name}: MISSING EXPORT`);
            failCount++;
            continue;
        }
        if (arg === null) {
            console.log(`  ${name}: SKIPPED (${desc})`);
            continue;
        }
        try {
            const result = ex[name](arg);
            console.log(`  ${name} = ${result} — ${desc}`);
            passCount++;
        } catch (e) {
            console.log(`  ${name}: ERROR — ${e.message}`);
            failCount++;
        }
    }

    console.log(`\n--- Testing eval_julia_to_bytes_vec("1+1") ---`);
    try {
        const result = ex['eval_julia_to_bytes_vec'](inputVec);
        console.log(`  Returned: ${result} (type: ${typeof result})`);
        const len = ex['eval_julia_result_length'](result);
        console.log(`  Length: ${len}`);
    } catch (e) {
        console.log(`  ERROR: ${e.message}`);
        // Try to find where it fails by checking the stack trace
        if (e.stack) {
            const lines = e.stack.split('\n').slice(0, 8);
            for (const l of lines) console.log(`    ${l}`);
        }
    }

    console.log(`\nDiagnostics: ${passCount} pass, ${failCount} fail`);
}

main().catch(e => { console.error(e); process.exit(1); });
