import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const bytes = readFileSync(join(__dirname, 'test_parse_nb.wasm'));
const mod = await rt.load(bytes, 'test_parse_nb');

const fn = mod.exports.test_parse_nb;

for (const [input, expected] of [['1', 2], ['hello', 6], ['1+2', 4]]) {
    const s = await rt.jsToWasmString(input);
    try {
        const result = fn(s);
        const pass = result === expected ? 'CORRECT' : `MISMATCH (expected ${expected})`;
        console.log(`test_parse_nb("${input}") = ${result} — ${pass}`);
    } catch (e) {
        console.log(`test_parse_nb("${input}") = CRASH: ${e.message}`);
        const lines = (e.stack||'').split('\n').filter(l => l.includes('wasm-function'));
        for (const l of lines.slice(0, 5)) console.log(`  ${l.trim()}`);
    }
}
