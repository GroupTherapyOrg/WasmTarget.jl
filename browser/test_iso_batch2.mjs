import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rc = fs.readFileSync(path.join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

async function testWasm(name, input, expected) {
    const wasmPath = path.join(__dirname, `test_${name}.wasm`);
    if (!fs.existsSync(wasmPath)) {
        console.log(`${name}: SKIP (no wasm file)`);
        return;
    }
    const rt = new WRT();
    const w = fs.readFileSync(wasmPath);
    try {
        const mod = await rt.load(w, name);
        const s = await rt.jsToWasmString(input);
        const result = mod.exports[`test_${name}`](s);
        const pass = result == BigInt(expected) || result == expected;
        console.log(`${name}("${input}"): result=${result}, expected=${expected} → ${pass ? "CORRECT" : "WRONG"}`);
    } catch (e) {
        console.log(`${name}("${input}"): FAIL — ${e.message.slice(0, 100)}`);
    }
}

(async () => {
    // Note: byte_range_first returns first(byte_range(child)) which for REVERSE iteration
    // is the LAST child (Integer "1" at position 3). Native returns 3.
    await testWasm("byte_range_first", "1+1", 3);
    await testWasm("head_raw", "1+1", 44);
    await testWasm("pjl_direct", "1", 1);
    await testWasm("leaf_val_no_isa", "1+1", 1);
    await testWasm("leaf_val_offset", "1+1", 1);
    // Re-test the original leaf_val that failed
    await testWasm("leaf_val", "1+1", 1);
})();
