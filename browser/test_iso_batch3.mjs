import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rc = fs.readFileSync(path.join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

async function testWasm(name, input, expected) {
    const wasmPath = path.join(__dirname, `test_${name}.wasm`);
    if (!fs.existsSync(wasmPath)) {
        console.log(`${name}: SKIP`);
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
    await testWasm("pil_simple", "1", 1);
    await testWasm("pil_simple", "42", 42);
    await testWasm("pjl_integer", "42", 42);
    await testWasm("pjl_returns", "1", 1);
    await testWasm("string_from_txtbuf", "42", 2);
    await testWasm("string_then_parse", "42", 42);
})();
