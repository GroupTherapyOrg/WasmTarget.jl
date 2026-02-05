/**
 * Diagnostic: Trace parsestmt.wasm runtime trap location.
 *
 * Gets a detailed error with stack trace to identify which
 * wasm function hits 'unreachable'.
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();

// Load parsestmt.wasm
const wasmPath = join(__dirname, "parsestmt.wasm");
const wasmBytes = await readFile(wasmPath);
const parser = await rt.load(wasmBytes, "parsestmt");

console.log(`Loaded parsestmt.wasm: ${Object.keys(parser.exports).length} exports`);

// List all exported functions
const funcExports = Object.entries(parser.exports)
    .filter(([k, v]) => typeof v === "function")
    .map(([k]) => k);
console.log(`Function exports (${funcExports.length}):`);
funcExports.forEach(f => console.log(`  ${f}`));

console.log("\n--- Calling parse_expr_string('1 + 1') ---\n");

const wasmStr = await rt.jsToWasmString("1 + 1");
try {
    const result = parser.exports.parse_expr_string(wasmStr);
    console.log(`SUCCESS: returned ${result} (${typeof result})`);
} catch (e) {
    console.log(`TRAP: ${e.constructor?.name}: ${e.message}`);
    console.log(`\nFull error:\n${e.stack || e}`);

    // Try to extract wasm function info from stack trace
    const stack = e.stack || "";
    const wasmFrames = stack.split("\n").filter(l => l.includes("wasm"));
    if (wasmFrames.length > 0) {
        console.log("\nWasm stack frames:");
        wasmFrames.forEach(f => console.log(`  ${f.trim()}`));
    }
}

// Also try calling individual exported functions to find which ones work
console.log("\n--- Testing individual exports ---\n");

// Test pure i32 functions
const testFuncs = [
    "is_operator_start_char",
    "is_word_operator",
    "is_closing_token",
    "is_number",
    "is_hexchar",
    "is_syntactic_operator"
];

for (const fname of testFuncs) {
    const fn = parser.exports[fname];
    if (fn) {
        try {
            const result = fn(43); // '+'
            console.log(`  ${fname}(43) = ${result} OK`);
        } catch (e) {
            console.log(`  ${fname}(43) TRAP: ${e.message}`);
        }
    }
}
