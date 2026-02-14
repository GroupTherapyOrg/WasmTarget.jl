import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const wasmBytes = await readFile(join(__dirname, "parsestmt.wasm"));
const parser = await rt.load(wasmBytes, "parsestmt");

const inputs = ["1+1", "1 +1", "1+ 1", "1 + 1", "a + b", "a+b", "x + 1", "x+1",
                "2*3", "2 * 3", "f(x)", "f( x )", "hello world", "hello"];
for (const input of inputs) {
    const s = await rt.jsToWasmString(input);
    try {
        const result = parser.exports.parse_expr_string(s);
        console.log(`"${input}" -> EXECUTE`);
    } catch (e) {
        const msg = e.message || String(e);
        console.log(`"${input}" -> TRAP: ${msg.substring(0, 80)}`);
    }
}
