import { readFileSync } from 'fs';
import { join } from 'path';

const d = new URL('.', import.meta.url).pathname;
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const w = readFileSync(join(d, 'test_pjl_branch_v2.wasm'));
const pa = await rt.load(w, 'test_pjl_branch_v2');

try {
    const result = pa.exports.test_pjl_branch();
    console.log(`result = ${result}`);
} catch(e) {
    console.log(`FAIL: ${e.message}`);
    console.log(`Stack: ${e.stack}`);
}
