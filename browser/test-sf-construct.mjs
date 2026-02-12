import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const w = readFileSync(join(__dirname, "test_sf_construct.wasm"));
const m = await rt.load(w, "t");

for (const input of ["1", "hello", "1+1", ""]) {
  const s = await rt.jsToWasmString(input);
  try {
    const r = m.exports.sf_construct(s);
    const rval = typeof r === 'bigint' ? Number(r) : r;
    console.log(`sf_construct("${input}") = ${rval} (expected: 1)`);
  } catch(e) {
    console.log(`sf_construct("${input}") FAIL: ${e.message}`);
    const lines = (e.stack||'').split('\n').filter(l => l.includes('wasm-function'));
    for (const l of lines.slice(0, 5)) console.log(`  ${l.trim()}`);
  }
}
