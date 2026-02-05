import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();
const wasmBytes = await readFile(join(__dirname, "read_bytes_sum.wasm"));
const mod = await rt.load(wasmBytes, "read_bytes_sum");

console.log("--- read_bytes_sum Tests ---\n");

const tests = [
    ["hi", 104 + 105],      // 'h'(104) + 'i'(105) = 209
    ["AB", 65 + 66],        // 'A'(65) + 'B'(66) = 131
    ["1+", 49 + 43],        // '1'(49) + '+'(43) = 92
];

let passed = 0, failed = 0;
for (const [str, expected] of tests) {
    const wasmStr = await rt.jsToWasmString(str);
    try {
        const result = mod.exports.read_bytes_sum(wasmStr);
        if (result === expected) {
            console.log(`  PASS: read_bytes_sum("${str}") = ${result}`);
            passed++;
        } else {
            console.log(`  FAIL: read_bytes_sum("${str}") = ${result}, expected ${expected}`);
            failed++;
        }
    } catch (e) {
        console.log(`  FAIL: read_bytes_sum("${str}") trapped: ${e.message || e}`);
        failed++;
    }
}

console.log(`\nResults: ${passed}/${passed+failed} passed`);
process.exit(failed > 0 ? 1 : 0);
