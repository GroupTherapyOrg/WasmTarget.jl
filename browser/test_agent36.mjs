import { readFileSync } from 'fs';
import { join } from 'path';

const d = new URL('.', import.meta.url).pathname;
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const w = readFileSync(join(d, 'parsestmt.wasm'));
const pa = await rt.load(w, 'parsestmt');

const tests = ["1", "42", "0", "-1", "100", "a", "x", "1+1", "1+2", "a+b", "+", ""];

for (const input of tests) {
    const s = await rt.jsToWasmString(input);
    try {
        const result = pa.exports.parse_expr_string(s);
        const isNull = result === null || result === undefined;
        console.log(`  "${input}" => ${isNull ? "NULL" : "non-null (" + typeof result + ")"}`);
    } catch(e) {
        if (e.message.includes("unreachable")) {
            console.log(`  "${input}" => UNREACHABLE (stub)`);
        } else {
            console.log(`  "${input}" => ERROR: ${e.message}`);
        }
    }
}
