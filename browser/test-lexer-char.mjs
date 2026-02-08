import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();
const wasmBytes = await readFile(join(__dirname, "get_lexer_char.wasm"));
const mod = await rt.load(wasmBytes, "get_lexer_char");

console.log("--- get_lexer_char Tests (Lexer chars[2]) ---\n");
const tests = [
    ["1", 49, "'1'"],
    ["x", 120, "'x'"],
    ["+", 43, "'+'"],
    ["A", 65, "'A'"],
    [" ", 32, "' '"],
];

let passed = 0, failed = 0;
for (const [str, expected, name] of tests) {
    const wasmStr = await rt.jsToWasmString(str);
    try {
        const result = mod.exports.get_lexer_char(wasmStr);
        if (result === expected) {
            console.log(`  PASS: get_lexer_char("${str}") = ${result} ${name}`);
            passed++;
        } else {
            console.log(`  FAIL: get_lexer_char("${str}") = ${result}, expected ${expected} ${name}`);
            failed++;
        }
    } catch (e) {
        console.log(`  FAIL: get_lexer_char("${str}") trapped: ${e.message || e}`);
        failed++;
    }
}
console.log(`\nResults: ${passed}/${passed+failed} passed`);
process.exit(failed > 0 ? 1 : 0);
