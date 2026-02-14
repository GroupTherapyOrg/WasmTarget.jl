import fs from 'fs';
import path from 'path';

const d = 'WasmTarget.jl/browser';
const rc = fs.readFileSync(path.join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const w = fs.readFileSync(path.join(d, 'parsestmt.wasm'));
const pa = await rt.load(w, 'parsestmt');

const input = process.argv[2] || '1';
const s = await rt.jsToWasmString(input);
try {
  const r = pa.exports.parse_expr_string(s);
  console.log(`"${input}": EXECUTES — result: ${r}`);
} catch (e) {
  console.log(`"${input}": FAIL — ${e.message}`);
  console.log(`  Stack: ${e.stack?.split('\n').filter(l => l.includes('wasm-function')).join(' -> ')}`);
}
