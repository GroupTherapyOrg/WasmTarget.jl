import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const wasmBytes = await readFile(join(__dirname, "parsestmt.wasm"));
const parser = await rt.load(wasmBytes, "parsestmt");

// Test "1 +1" which traps
const s = await rt.jsToWasmString("1 +1");
try {
    const result = parser.exports.parse_expr_string(s);
    console.log("SUCCESS:", result);
} catch (e) {
    console.log("Error:", e.message);
    console.log("Stack:", e.stack);
}
