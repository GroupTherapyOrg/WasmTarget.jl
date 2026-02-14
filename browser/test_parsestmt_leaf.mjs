import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rtCode = readFileSync(join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rtCode + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const bytes = readFileSync(join(__dirname, 'test_parsestmt_leaf.wasm'));
const mod = await rt.load(bytes, 'test_leaf');

for (const input of ['1', '42', '1+1', 'x', '']) {
  const s = await rt.jsToWasmString(input);
  try {
    const result = mod.exports.test_parsestmt_leaf(s);
    console.log(`test_parsestmt_leaf("${input}") = ${result} — ${result === 1 ? 'CORRECT' : 'WRONG'}`);
  } catch (e) {
    console.log(`test_parsestmt_leaf("${input}") — CRASH: ${e.message.substring(0, 100)}`);
  }
}
