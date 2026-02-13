import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

async function testSymbolEq(wasmFile, testCases, label) {
    console.log(`\n=== ${label} ===`);
    const rt = new WRT();
    const bytes = readFileSync(join(__dirname, wasmFile));
    const mod = await rt.load(bytes, wasmFile.replace('.wasm', ''));

    // Get the exported function (first non-memory export)
    const exportNames = Object.keys(mod.exports).filter(k => typeof mod.exports[k] === 'function');
    const fn = mod.exports[exportNames[0]];
    console.log(`  Export: ${exportNames[0]}`);

    for (const [input, expected] of testCases) {
        const sym = await rt.jsToWasmString(input);
        try {
            const result = fn(sym);
            const pass = result === expected ? 'CORRECT' : `MISMATCH (expected ${expected})`;
            console.log(`  ${label}("${input}") = ${result} — ${pass}`);
        } catch (e) {
            console.log(`  ${label}("${input}") = CRASH: ${e.message}`);
        }
    }
}

await testSymbolEq('test_sym_eq1.wasm', [
    ['hello', 1],
    ['world', 0],
    ['statement', 0],
], 'test_sym_eq1');

await testSymbolEq('test_sym_dispatch.wasm', [
    ['all', 1],
    ['statement', 2],
    ['atom', 3],
    ['other', 0],
], 'test_sym_dispatch');

await testSymbolEq('test_sym_phi.wasm', [
    ['all', 10],
    ['statement', 20],
    ['toplevel', 10],
    ['other', 0],
], 'test_sym_phi');
