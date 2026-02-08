/**
 * PURE-316 Diagnostic: Compare IOBuffer(String) vs IOBuffer(unsafe_wrap(String))
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();

// Test 1: IOBuffer(s) directly
console.log("--- Test 1: read_first_byte_direct(s) -> IOBuffer(s) ---");
try {
    const wasmBytes = await readFile(join(__dirname, "test_read_direct.wasm"));
    const mod = await rt.load(wasmBytes, "direct");
    const wasmStr = await rt.jsToWasmString("A");
    const result = mod.exports.read_first_byte_direct(wasmStr);
    console.log("Result:", result, "(expected 65 for 'A')");
    console.log(result === 65 ? "PASS" : "FAIL");
} catch (e) {
    console.log("ERROR:", e.message || String(e));
}

// Test 2: IOBuffer(unsafe_wrap(Vector{UInt8}, s))
console.log("\n--- Test 2: read_byte_wrap(s) -> IOBuffer(unsafe_wrap(s)) ---");
try {
    const wasmBytes = await readFile(join(__dirname, "test_read_wrap.wasm"));
    const mod = await rt.load(wasmBytes, "wrap");
    const wasmStr = await rt.jsToWasmString("A");
    const result = mod.exports.read_byte_wrap(wasmStr);
    console.log("Result:", result, "(expected 65 for 'A')");
    console.log(result === 65 ? "PASS" : "FAIL");
} catch (e) {
    console.log("ERROR:", e.message || String(e));
}
