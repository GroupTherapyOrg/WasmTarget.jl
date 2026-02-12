import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const w = readFileSync(join(__dirname, "test_box_unbox_multi.wasm"));
const m = await rt.load(w, "t");

const s = await rt.jsToWasmString("hello");

try {
  const r = m.exports.test_box_unbox(s);
  console.log("test_box_unbox('hello') =", r, "(expected: 104n for 'h')");
} catch(e) {
  console.log("test_box_unbox FAIL:", e.message);
  const lines = (e.stack||'').split('\n').filter(l => l.includes('wasm-function'));
  for (const l of lines) console.log(`  ${l.trim()}`);
}

try {
  const r = m.exports.test_box_unbox(await rt.jsToWasmString("1"));
  console.log("test_box_unbox('1') =", r, "(expected: 49n for '1')");
} catch(e) {
  console.log("test_box_unbox('1') FAIL:", e.message);
}
