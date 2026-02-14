// Test parse_julia_literal isolation after boxing fix
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = readFileSync(join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WasmTargetRuntime = new Function(runtimeCode + '\nreturn WasmTargetRuntime;')();

async function main() {
    const rt = new WasmTargetRuntime();
    const wasmBytes = readFileSync(join(__dirname, 'test_pjl.wasm'));
    const mod = await rt.load(wasmBytes, 'test_pjl');

    // Test parse_julia_literal wrapper
    // Native Julia: test_pjl("1") = 1, test_pjl("42") = 42
    for (const [input, expected] of [["1", 1], ["42", 42]]) {
        const s = await rt.jsToWasmString(input);
        try {
            const result = mod.exports.test_pjl(s);
            const match = result === BigInt(expected) || result === expected;
            console.log(`test_pjl("${input}"): got ${result}, expected ${expected} — ${match ? 'CORRECT' : 'MISMATCH'}`);
        } catch (e) {
            console.log(`test_pjl("${input}"): FAIL — ${e.message}`);
        }
    }
}

main().catch(e => console.error('Error:', e));
