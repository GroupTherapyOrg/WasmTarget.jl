import { readFileSync } from 'fs';
import { join } from 'path';

const d = new URL('.', import.meta.url).pathname;
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const w = readFileSync(join(d, 'parsestmt.wasm'));
const pa = await rt.load(w, 'parsestmt');

// Test "1+1" with stack trace
const s = await rt.jsToWasmString('1+1');
try {
    const result = pa.exports.parse_expr_string(s);
    console.log(`"1+1" => EXECUTES, result=${result}`);
} catch(e) {
    console.log(`"1+1" => FAIL: ${e.message}`);
    console.log(`Stack: ${e.stack}`);
}

// Also test "x"
const s2 = await rt.jsToWasmString('x');
try {
    const result = pa.exports.parse_expr_string(s2);
    console.log(`"x" => EXECUTES, result=${result}`);
} catch(e) {
    console.log(`"x" => FAIL: ${e.message}`);
}
