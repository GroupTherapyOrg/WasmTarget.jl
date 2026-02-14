import { readFileSync } from 'fs';
import { join } from 'path';

const d = new URL('.', import.meta.url).pathname;
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const w = readFileSync(join(d, 'parsestmt.wasm'));
const pa = await rt.load(w, 'parsestmt');

const inputs = ['1', '42', '1+1', 'x', '', '-1', '(1)', 'true'];
for (const input of inputs) {
    const s = await rt.jsToWasmString(input);
    try {
        const result = pa.exports.parse_expr_string(s);
        console.log(`"${input}" => EXECUTES, result=${result}`);
    } catch(e) {
        console.log(`"${input}" => FAIL: ${e.message.substring(0, 120)}`);
    }
}
