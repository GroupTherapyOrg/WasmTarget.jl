import { readFileSync } from 'fs';
import { join } from 'path';

const d = 'WasmTarget.jl/browser';
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

async function testWasm(filename, funcname, expected) {
    const rt = new WRT();
    try {
        const bytes = readFileSync(join(d, filename));
        const mod = await rt.load(bytes, funcname);
        const result = mod.exports[funcname]();
        const status = result === expected ? 'CORRECT' : 'MISMATCH';
        console.log(`${funcname}: Wasm=${result}, Expected=${expected} — ${status}`);
        return result === expected;
    } catch (e) {
        console.log(`${funcname}: FAIL — ${e.message}`);
        return false;
    }
}

(async () => {
    await testWasm('test_parse_output_len.wasm', 'test_parse_output_len', 6);
    await testWasm('test_cursor_kind.wasm', 'test_cursor_kind', 717);
    await testWasm('test_is_leaf.wasm', 'test_is_leaf', 0);
    await testWasm('test_children_count.wasm', 'test_children_count', 3);
})();
