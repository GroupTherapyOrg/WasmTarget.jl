import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();
const wasmBytes = await readFile(join(__dirname, "read_io_byte.wasm"));
const mod = await rt.load(wasmBytes, "read_io_byte");

console.log("--- read_io_byte (unsafe_wrap path) Tests ---\n");
const tests = [["1", 49], ["x", 120], ["A", 65], ["hello", 104]];
let passed = 0, failed = 0;
for (const [str, expected] of tests) {
    const wasmStr = await rt.jsToWasmString(str);
    try {
        const result = mod.exports.read_io_byte(wasmStr);
        if (result === expected) {
            console.log(`  PASS: read_io_byte("${str}") = ${result}`);
            passed++;
        } else {
            console.log(`  FAIL: read_io_byte("${str}") = ${result}, expected ${expected}`);
            failed++;
        }
    } catch (e) {
        console.log(`  FAIL: read_io_byte("${str}") trapped: ${e.message || e}`);
        failed++;
    }
}
console.log(`\nResults: ${passed}/${passed+failed} passed`);
process.exit(failed > 0 ? 1 : 0);
