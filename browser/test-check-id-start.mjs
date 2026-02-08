import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();
const wasmBytes = await readFile(join(__dirname, "check_id_start.wasm"));
const mod = await rt.load(wasmBytes, "check_id_start");

console.log("--- check_id_start (is_id_start_char) Tests ---\n");
const tests = [
    ["x", 120, 1],
    ["1", 49, 0],
    ["+", 43, 0],
    ["A", 65, 1],
    ["_", 95, 1],
    ["Z", 90, 1],
    ["a", 97, 1],
    ["0", 48, 0],
    [" ", 32, 0],
];
let passed = 0, failed = 0;
for (const [name, codepoint, expected] of tests) {
    try {
        const result = mod.exports.check_id_start(codepoint);
        if (result === expected) {
            console.log(`  PASS: is_id_start('${name}'=${codepoint}) = ${result}`);
            passed++;
        } else {
            console.log(`  FAIL: is_id_start('${name}'=${codepoint}) = ${result}, expected ${expected}`);
            failed++;
        }
    } catch (e) {
        console.log(`  FAIL: is_id_start('${name}'=${codepoint}) trapped: ${e.message || e}`);
        failed++;
    }
}
console.log(`\nResults: ${passed}/${passed+failed} passed`);
process.exit(failed > 0 ? 1 : 0);
