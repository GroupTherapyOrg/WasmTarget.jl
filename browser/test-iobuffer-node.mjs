/**
 * Test IOBuffer byte reading: read_first_byte(s::String) = Base.read(IOBuffer(s), UInt8)
 * This tests the same path ParseStream uses internally.
 */
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();

console.log("--- IOBuffer Byte Reading Tests ---\n");

// Load the read_first_byte module
let mod;
try {
    const wasmBytes = await readFile(join(__dirname, "read_first_byte.wasm"));
    mod = await rt.load(wasmBytes, "read_first_byte");
    console.log("PASS: Module loaded, exports:", Object.keys(mod.exports).join(", "));
} catch (e) {
    console.log("FATAL: Cannot load:", e.message);
    process.exit(1);
}

// Test with various ASCII strings
const tests = [
    ["1", 49],     // '1' = 0x31 = 49
    ["A", 65],     // 'A' = 0x41 = 65
    ["a", 97],     // 'a' = 0x61 = 97
    ["hello", 104], // 'h' = 0x68 = 104
    [" ", 32],     // space = 0x20 = 32
];

let passed = 0, failed = 0;
for (const [input, expected] of tests) {
    const wasmStr = await rt.jsToWasmString(input);
    try {
        const result = mod.exports.read_first_byte(wasmStr);
        if (result === expected) {
            console.log(`  PASS: read_first_byte("${input}") = ${result}`);
            passed++;
        } else {
            console.log(`  FAIL: read_first_byte("${input}") = ${result}, expected ${expected}`);
            failed++;
        }
    } catch (e) {
        console.log(`  FAIL: read_first_byte("${input}") trapped: ${e.message || e}`);
        failed++;
    }
}

console.log(`\nResults: ${passed}/${passed+failed} passed`);
process.exit(failed > 0 ? 1 : 0);
