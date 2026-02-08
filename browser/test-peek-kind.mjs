/**
 * Diagnostic test: peek_kind(s) — what token does the parser see first?
 *
 * Expected: peek_kind("1") should return 44 (Integer/K"Integer")
 * Bug: ParseStream's IOBuffer gets broken data, returning 762 (ErrorInvalidUTF8)
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();

const wasmBytes = await readFile(join(__dirname, "peek_kind.wasm"));
const mod = await rt.load(wasmBytes, "peek_kind");

console.log("Exports:", Object.keys(mod.exports).length);
console.log("peek_kind exists:", typeof mod.exports.peek_kind === "function");

const wasmStr = await rt.jsToWasmString("1");
console.log("Testing peek_kind('1')...");

try {
    const result = mod.exports.peek_kind(wasmStr);
    console.log("Result:", result);
    console.log("Expected 44 (Integer). Got:", result);
    if (result === 44) {
        console.log("PASS: Parser correctly identifies '1' as Integer token");
    } else if (result === 762) {
        console.log("FAIL: Got ErrorInvalidUTF8 — IOBuffer is broken");
    } else {
        console.log("FAIL: Unexpected token kind:", result);
    }
} catch (e) {
    console.log("ERROR:", e.message || String(e));
}
