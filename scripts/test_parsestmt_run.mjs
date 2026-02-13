import fs from 'fs';
import path from 'path';

const d = path.join(import.meta.dirname, '..', 'browser');
const rc = fs.readFileSync(path.join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const w = fs.readFileSync(path.join(d, 'parsestmt.wasm'));
const pa = await rt.load(w, 'parsestmt');
const s = await rt.jsToWasmString('1');
try {
  const result = pa.exports.parse_expr_string(s);
  console.log('PASS:', result);
} catch (e) {
  console.log('FAIL:', e.message);
  // Get a stack trace with function indices
  console.log('Stack:', e.stack?.split('\n').slice(0, 10).join('\n'));
}
