import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rtCode = readFileSync(join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rtCode + '\nreturn WasmTargetRuntime;')();

async function testWasmString(filename, funcName, input, expected) {
  const rt = new WRT();
  try {
    const bytes = readFileSync(join(__dirname, filename));
    const mod = await rt.load(bytes, funcName.replace('test_', ''));
    const s = await rt.jsToWasmString(input);
    const result = mod.exports[funcName](s);
    const status = result === expected ? 'CORRECT' : `WRONG (got ${result}, expected ${expected})`;
    console.log(`  ${funcName}("${input}") = ${result} — ${status}`);
    return result === expected;
  } catch (e) {
    console.log(`  ${funcName}("${input}") — CRASH: ${e.message.substring(0, 120)}`);
    return false;
  }
}

console.log('=== parse_julia_literal with Runtime String Input ===');
console.log('');

console.log('test_pjl_result (K"Integer" head):');
await testWasmString('test_pjl_result.wasm', 'test_pjl_result', '1', 1);
await testWasmString('test_pjl_result.wasm', 'test_pjl_result', '42', 42);
console.log('');

console.log('test_pjl_ident (K"Identifier" head):');
await testWasmString('test_pjl_ident.wasm', 'test_pjl_ident', 'x', 1);
console.log('');

console.log('Decode: 1=Int64 val, -1=Symbol, -2=Nothing, -3=Bool, -6=String, -999=unknown');
