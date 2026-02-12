import { readFileSync } from 'fs';
import { join } from 'path';

const d = "WasmTarget.jl/browser";
const rc = readFileSync(join(d, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const w = readFileSync(join(d, "parsestmt.wasm"));
const pa = await rt.load(w, "parsestmt");

for (const input of ["1", "x", "1+1"]) {
  const s = await rt.jsToWasmString(input);
  try {
    const result = pa.exports.parse_expr_string(s);
    console.log(`Input "${input}": PASS (result=${result})`);
  } catch (e) {
    console.log(`Input "${input}": FAIL: ${e.message}`);
  }
}
