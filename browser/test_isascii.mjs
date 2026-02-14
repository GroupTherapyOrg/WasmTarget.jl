import { readFileSync } from 'fs';
import { join } from 'path';

const d = new URL('.', import.meta.url).pathname;
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const w = readFileSync(process.argv[2]);
const mod = await rt.load(w, 'test');

for (const input of ["+", "x", "hello", "1"]) {
    const s = await rt.jsToWasmString(input);
    try {
        const result = mod.exports.test_normalize(s);
        console.log(`normalize_identifier("${input}") = ${result} (expected 1 for ASCII)`);
    } catch(e) {
        console.log(`normalize_identifier("${input}") FAIL: ${e.message}`);
    }
}
