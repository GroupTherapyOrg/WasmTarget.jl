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
    console.log(`  ${funcName}("${input}") — CRASH: ${e.message.substring(0, 100)}`);
    return false;
  }
}

async function testWasmNoArgs(filename, funcName, expected) {
  const rt = new WRT();
  try {
    const bytes = readFileSync(join(__dirname, filename));
    const mod = await rt.load(bytes, funcName.replace('test_', ''));
    const result = mod.exports[funcName]();
    const status = result === expected ? 'CORRECT' : `WRONG (got ${result}, expected ${expected})`;
    console.log(`  ${funcName}() = ${result} — ${status}`);
    return result === expected;
  } catch (e) {
    console.log(`  ${funcName}() — CRASH: ${e.message.substring(0, 100)}`);
    return false;
  }
}

console.log('=== Parse Literal Isolation Tests ===');
console.log('');

console.log('Test: parse_int_literal');
await testWasmString('test_parse_int_lit.wasm', 'test_parse_int_lit', '1', 1);
await testWasmString('test_parse_int_lit.wasm', 'test_parse_int_lit', '42', 42);
await testWasmString('test_parse_int_lit.wasm', 'test_parse_int_lit', '0', 0);
console.log('');

console.log('Test: parse_julia_literal from buffer');
await testWasmNoArgs('test_parse_literal_from_buf.wasm', 'test_parse_literal_from_buf', 1);
