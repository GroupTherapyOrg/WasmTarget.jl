import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const w = readFileSync(join(__dirname, "test_fake_stream.wasm"));
const m = await rt.load(w, "t");

for (const input of ["1", "hello", "a\nb", ""]) {
  const s = await rt.jsToWasmString(input);
  try {
    const r = m.exports.count_chars(s);
    const rval = typeof r === 'bigint' ? Number(r) : r;
    console.log(`count_chars("${input.replace(/\n/g, '\\n')}") = ${rval} (expected: ${input.length})`);
  } catch(e) {
    console.log(`count_chars("${input.replace(/\n/g, '\\n')}") FAIL: ${e.message}`);
    const lines = (e.stack||'').split('\n').filter(l => l.includes('wasm-function'));
    for (const l of lines) console.log(`  ${l.trim()}`);
  }
}
