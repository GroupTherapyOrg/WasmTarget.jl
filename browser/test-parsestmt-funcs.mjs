/**
 * Test individual exported functions from parsestmt.wasm
 * to narrow down where the hang occurs.
 */
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();
const wasmBytes = await readFile(join(__dirname, "parsestmt.wasm"));
const parser = await rt.load(wasmBytes, "parsestmt");

console.log("parsestmt.wasm loaded:", Object.keys(parser.exports).length, "exports\n");

// List all exported function names
const funcNames = Object.keys(parser.exports).filter(k => typeof parser.exports[k] === "function");
console.log("Exported functions:");
for (const name of funcNames.sort()) {
    console.log(`  ${name}`);
}

// Test pure i32 functions (no string input)
console.log("\n--- Pure i32 function tests ---");
const pureFuncs = [
    "is_operator_start_char",
    "is_identifier_start_char",
    "is_identifier_char",
    "is_never_id_char",
    "is_dottable_operator_start_char",
];
for (const name of pureFuncs) {
    const fn = parser.exports[name];
    if (fn) {
        try {
            const result = fn(43); // '+'
            console.log(`  ${name}('+') = ${result}`);
        } catch (e) {
            console.log(`  ${name}('+') TRAP: ${e.message || e}`);
        }
    }
}

// Test str_length on a string
console.log("\n--- String function tests ---");
const wasmStr = await rt.jsToWasmString("1 + 1");
const strLen = await rt.wasmToJsString(wasmStr);
console.log(`  String roundtrip: "${strLen}" (length check)`);

// Check first_byte if available
const firstByte = parser.exports.first_byte;
if (firstByte) {
    try {
        const b = firstByte(wasmStr);
        console.log(`  first_byte("1 + 1") = ${b} (expected 49)`);
    } catch (e) {
        console.log(`  first_byte TRAP: ${e.message || e}`);
    }
}

console.log("\nDone.");
