// Debug script for parsestmt.wasm — captures detailed error info
import { readFileSync } from 'fs';
import { join } from 'path';

const dir = new URL('.', import.meta.url).pathname;
const runtimeCode = readFileSync(join(dir, 'wasmtarget-runtime.js'), 'utf-8');
const WasmTargetRuntime = new Function(runtimeCode + '\nreturn WasmTargetRuntime;')();

const rt = new WasmTargetRuntime();
const wasmBytes = readFileSync(join(dir, 'parsestmt.wasm'));

try {
  const mod = await rt.load(wasmBytes, 'parsestmt');
  console.log('Module loaded, exports:', Object.keys(mod.exports).filter(k => typeof mod.exports[k] === 'function'));

  const s = await rt.jsToWasmString('1');
  console.log('String created:', s);

  try {
    const result = mod.exports.parse_expr_string(s);
    console.log('PASS:', result);
  } catch (e) {
    console.log('FAIL:', e.message);
    console.log('Stack:', e.stack);
  }
} catch (e) {
  console.log('LOAD FAIL:', e.message);
  console.log('Stack:', e.stack);
}
