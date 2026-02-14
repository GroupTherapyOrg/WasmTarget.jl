import { readFileSync } from 'fs';
import { join } from 'path';

const d = new URL('.', import.meta.url).pathname;
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();

// Test pjl_branch
try {
    const w1 = readFileSync(join(d, 'test_pjl_branch_v2.wasm'));
    const pa1 = await rt.load(w1, 'test_pjl_branch_v2');
    const result1 = pa1.exports.test_pjl_branch();
    console.log(`test_pjl_branch() = ${result1} (100=Int64, -1=Symbol, 0=nothing)`);
} catch(e) {
    console.log(`test_pjl_branch FAIL: ${e.message}`);
}

// Test pjl_call
try {
    const rt2 = new WRT();
    const w2 = readFileSync(join(d, 'test_pjl_call_v2.wasm'));
    const pa2 = await rt2.load(w2, 'test_pjl_call_v2');
    const result2 = pa2.exports.test_pjl_call();
    console.log(`test_pjl_call() = ${result2} (1=not-nothing, 0=nothing)`);
} catch(e) {
    console.log(`test_pjl_call FAIL: ${e.message}`);
}
