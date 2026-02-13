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
// "1":   bump_trivia_added=0, bump_added=1, la_before=1, la_after_trivia=1
// " 1":  bump_trivia_added=1, bump_added=1, la_before=1, la_after_trivia=2
// "  1": bump_trivia_added=1, bump_added=1, la_before=1, la_after_trivia=2

await testFn('test_bump_trivia_count.wasm', [
    ['1', 0],
    [' 1', 1],
    ['  1', 1],
], 'test_bump_trivia_count');

await testFn('test_bump_count.wasm', [
    ['1', 1],
    [' 1', 1],
], 'test_bump_count');

await testFn('test_lookahead_idx_before.wasm', [
    ['1', 1],
], 'test_lookahead_idx_before');

await testFn('test_lookahead_idx_after_trivia.wasm', [
    ['1', 1],
    [' 1', 2],
], 'test_lookahead_idx_after_trivia');
