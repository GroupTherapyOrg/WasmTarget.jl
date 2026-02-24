// PURE-6024 Agent 21: Test individual diagnostic functions
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);

    const makeByteVec = instance.exports['make_byte_vec'];
    const setByteVec = instance.exports['set_byte_vec!'];

    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = makeByteVec(bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            setByteVec(vec, i + 1, bytes[i]);
        }
        return vec;
    }

    const code = "1+1";
    const vec = jsToWasmBytes(code);

    // List all diagnostic exports
    const diagExports = Object.keys(instance.exports).filter(k =>
        k.startsWith('eval_julia_test_') && typeof instance.exports[k] === 'function'
    );
    console.log("Diagnostic exports:", diagExports);

    // Test each diagnostic function
    const tests = [
        'eval_julia_test_string_from_bytes',
        'eval_julia_test_parse_int',
        'eval_julia_test_ps_create',
        'eval_julia_test_parse_only',
        'eval_julia_test_build_tree',
        'eval_julia_test_substring',
        'eval_julia_test_tree_nranges',
        'eval_julia_test_parse',
    ];

    for (const name of tests) {
        const fn = instance.exports[name];
        if (!fn) {
            console.log(`  ${name}: NOT EXPORTED`);
            continue;
        }
        try {
            // Need fresh vec for each test since some may consume it
            const v = jsToWasmBytes(code);
            const result = fn(v);
            console.log(`  ${name}("${code}") = ${result}`);
        } catch (e) {
            console.log(`  ${name}("${code}") = ERROR: ${e.message}`);
        }
    }

    // Also test with "42" for parse_int
    try {
        const v42 = jsToWasmBytes("42");
        const r = instance.exports['eval_julia_test_parse_int'](v42);
        console.log(`  eval_julia_test_parse_int("42") = ${r}`);
    } catch (e) {
        console.log(`  eval_julia_test_parse_int("42") = ERROR: ${e.message}`);
    }

    // Test eval_julia_to_bytes_vec with better error details
    console.log("\n--- eval_julia_to_bytes_vec test ---");
    try {
        const v = jsToWasmBytes("1+1");
        const result = instance.exports.eval_julia_to_bytes_vec(v);
        console.log(`  Result: ${result} (type: ${typeof result})`);
    } catch (e) {
        console.log(`  ERROR: ${e.constructor.name}: ${e.message}`);
        if (e instanceof WebAssembly.RuntimeError) {
            console.log(`  Stack: ${e.stack?.split('\n').slice(0, 10).join('\n')}`);
        }
        if (e instanceof WebAssembly.Exception) {
            console.log(`  This is a WASM exception (thrown by Julia code via throw/error)`);
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
