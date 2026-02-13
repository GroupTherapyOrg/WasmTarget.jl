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

// Ground truth:
// "1":   before=1, after_stmt=2, after_all=3
// "hello": before=1, after_stmt=2, after_all=3
// "1+2": before=1, after_stmt=5, after_all=6

await testFn('test_output_before.wasm', [
    ['1', 1],
    ['hello', 1],
], 'test_output_before');

await testFn('test_output_after.wasm', [
    ['1', 2],
    ['hello', 2],
    ['1+2', 5],
], 'test_output_after');

await testFn('test_output_after_all.wasm', [
    ['1', 3],
    ['hello', 3],
    ['1+2', 6],
], 'test_output_after_all');
