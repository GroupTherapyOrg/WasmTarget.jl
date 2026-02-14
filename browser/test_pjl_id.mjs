import { readFileSync } from 'fs';
import { join } from 'path';

const d = new URL('.', import.meta.url).pathname;
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const w = readFileSync(join(d, 'test_pjl_id.wasm'));
const mod = await rt.load(w, 'test');

for (const input of ["+", "x", "hello", "1"]) {
    const s = await rt.jsToWasmString(input);
    try {
        const result = mod.exports.test_pjl_id(s);
        console.log(`parse_julia_literal(Identifier, "${input}") = ${result} (1=Symbol, 0=other)`);
    } catch(e) {
        console.log(`parse_julia_literal(Identifier, "${input}") FAIL: ${e.message}`);
    }
}
