import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

async function testFn(wasmFile, testCases, label) {
    console.log(`\n=== ${label} ===`);
    const rt = new WRT();
    const bytes = readFileSync(join(__dirname, wasmFile));
    const mod = await rt.load(bytes, wasmFile.replace('.wasm', ''));
    const exportNames = Object.keys(mod.exports).filter(k => typeof mod.exports[k] === 'function');
    const fn = mod.exports[exportNames[0]];

    for (const [input, expected] of testCases) {
        const s = await rt.jsToWasmString(input);
        try {
            const result = fn(s);
            const pass = result === expected ? 'CORRECT' : `MISMATCH (expected ${expected}, got ${result})`;
            console.log(`  ${label}("${input}") = ${result} — ${pass}`);
        } catch (e) {
            console.log(`  ${label}("${input}") = CRASH: ${e.message}`);
        }
    }
}

// Ground truth from native Julia:
// "1": output_count=2, next_byte=2, nb_before=1
// "hello": output_count=2, next_byte=6, nb_before=1
// "1+2": output_count=5, next_byte=4, nb_before=1

await testFn('test_output_count.wasm', [
    ['1', 2],
    ['hello', 2],
    ['1+2', 5],
], 'test_output_count');

await testFn('test_stream_nb.wasm', [
    ['1', 2],
    ['hello', 6],
    ['1+2', 4],
], 'test_stream_nb');

await testFn('test_stream_nb_before.wasm', [
    ['1', 1],
    ['hello', 1],
], 'test_stream_nb_before');
