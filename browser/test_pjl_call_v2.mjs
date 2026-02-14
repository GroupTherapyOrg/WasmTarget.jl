import { readFileSync } from 'fs';
import { join } from 'path';

const d = new URL('.', import.meta.url).pathname;
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const w = readFileSync(join(d, 'test_pjl_call_v2.wasm'));
const pa = await rt.load(w, 'test_pjl_call_v2');

try {
    const result = pa.exports.test_pjl_call();
    console.log(`test_pjl_call() = ${result}`);
    if (result === 1) {
        console.log("CORRECT: parse_julia_literal returns non-nothing for K\"Integer\"");
    } else if (result === 0) {
        console.log("WRONG: parse_julia_literal returns nothing — phi boxing NOT working");
    } else {
        console.log(`UNEXPECTED: result = ${result}`);
    }
} catch(e) {
    console.log(`FAIL: ${e.message}`);
}
