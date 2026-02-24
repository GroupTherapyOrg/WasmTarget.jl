// Test: does test_parse_only work in the full module context?
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    const wasmPath = join(__dirname, '..', 'output', 'test_parse_context.wasm');
    const wasmBytes = await readFile(wasmPath);
    const imports = { Math: { pow: Math.pow } };

    console.log("Loading module...");
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const e = instance.exports;
    const funcExports = Object.keys(e).filter(k => typeof e[k] === 'function');
    console.log(`Loaded: ${funcExports.length} exports`);
    console.log("First 10:", funcExports.slice(0, 10).join(', '));

    // Create "1+1" bytes using module's make_byte_vec
    const vec = e['make_byte_vec'](3);
    e['set_byte_vec!'](vec, 1, 49);
    e['set_byte_vec!'](vec, 2, 43);
    e['set_byte_vec!'](vec, 3, 49);

    // Test 1: test_parse_only
    console.log("\n--- test_parse_only('1+1') ---");
    try {
        const result = e['test_parse_only'](vec);
        console.log(`  Result: ${result} → ${result === 1 ? "PASS" : "FAIL"}`);
    } catch (err) {
        console.log(`  ERROR: ${err.message}`);
        if (err.stack) {
            const lines = err.stack.split('\n').slice(0, 5);
            for (const line of lines) console.log(`  ${line}`);
        }
    }

    // Test 2: eval_julia_to_bytes_vec (recreate vec in case it was consumed)
    const vec2 = e['make_byte_vec'](3);
    e['set_byte_vec!'](vec2, 1, 49);
    e['set_byte_vec!'](vec2, 2, 43);
    e['set_byte_vec!'](vec2, 3, 49);

    console.log("\n--- eval_julia_to_bytes_vec('1+1') ---");
    try {
        const result = e['eval_julia_to_bytes_vec'](vec2);
        console.log("  SUCCESS!");
    } catch (err) {
        console.log(`  ERROR: ${err.message}`);
        if (err.stack) {
            const lines = err.stack.split('\n').slice(0, 5);
            for (const line of lines) console.log(`  ${line}`);
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
