import { readFileSync } from 'fs';
import { join } from 'path';

const d = "WasmTarget.jl/browser";
const rc = readFileSync(join(d, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const w = readFileSync(join(d, "parsestmt.wasm"));
const pa = await rt.load(w, "parsestmt");
const s = await rt.jsToWasmString("1");

try {
  pa.exports.parse_expr_string(s);
  console.log("PASS");
} catch (e) {
  console.log("FAIL:", e.message);
  console.log("Stack:", e.stack);
}
