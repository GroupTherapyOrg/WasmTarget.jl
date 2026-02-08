import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();
const wasmBytes = await readFile(join(__dirname, "peek_diag.wasm"));
const mod = await rt.load(wasmBytes, "peek_diag");

// Create wasm string "1"
const wasmStr = await rt.jsToWasmString("1");
console.log("wasmStr:", wasmStr);

// Call test_peek_kind
try {
    const result = mod.exports.test_peek_kind(wasmStr);
    console.log("test_peek_kind(\"1\") =", result, "(expected 44=Integer)");
    if (result === 44) {
        console.log("PASS: Kind is correct");
    } else {
        console.log("FAIL: Kind is wrong! Expected 44, got", result);
    }
} catch (e) {
    console.error("ERROR:", e.message);
    console.error(e.stack);
}
