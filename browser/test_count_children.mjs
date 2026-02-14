import { readFileSync } from 'fs';
import { join } from 'path';

const d = 'WasmTarget.jl/browser';
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

(async () => {
    const rt = new WRT();
    const testbytes = readFileSync(join(d, 'test_children_count.wasm'));
    const mod = await rt.load(testbytes, 'test_count');

    try {
        const result = mod.exports.test_children_count();
        console.log('Wasm result:', result);
        console.log('Expected: 3 (call node has 3 children: Integer, Identifier, Integer)');
        console.log(result === 3 ? 'CORRECT' : 'MISMATCH');
    } catch (e) {
        console.log('FAIL:', e.message);
    }
})();
