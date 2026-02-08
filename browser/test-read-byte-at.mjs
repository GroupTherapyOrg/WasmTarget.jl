import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();
const wasmBytes = await readFile(join(__dirname, "read_byte_at.wasm"));
const mod = await rt.load(wasmBytes, "read_byte_at");

console.log("--- read_byte_at Tests ---\n");
let passed = 0, failed = 0;

const tests = [
    ["hello", 1, 104],  // 'h'
    ["hello", 2, 101],  // 'e'
    ["hello", 3, 108],  // 'l'
    ["hello", 5, 111],  // 'o'
    ["1 + 1", 1, 49],   // '1'
    ["1 + 1", 2, 32],   // ' '
    ["1 + 1", 3, 43],   // '+'
];

for (const [str, pos, expected] of tests) {
    const wasmStr = await rt.jsToWasmString(str);
    try {
        const result = mod.exports.read_byte_at(wasmStr, BigInt(pos));
        if (result === expected) {
            console.log(`  PASS: read_byte_at("${str}", ${pos}) = ${result} ('${String.fromCharCode(result)}')`);
            passed++;
        } else {
            console.log(`  FAIL: read_byte_at("${str}", ${pos}) = ${result}, expected ${expected}`);
            failed++;
        }
    } catch (e) {
        console.log(`  FAIL: read_byte_at("${str}", ${pos}) trapped: ${e.message || e}`);
        failed++;
    }
}

console.log(`\nResults: ${passed}/${passed+failed} passed`);
process.exit(failed > 0 ? 1 : 0);
