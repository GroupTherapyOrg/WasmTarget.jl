import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rtCode = readFileSync(join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rtCode + '\nreturn WasmTargetRuntime;')();

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
    console.log(`  ${funcName}() — CRASH: ${e.message.substring(0, 120)}`);
    return false;
  }
}

console.log('=== Parse Literal Diagnostic Tests ===');
console.log('');

console.log('SyntaxHead Kind construction:');
await testWasmNoArgs('test_syntax_head_kind.wasm', 'test_syntax_head_kind', 44);
console.log('');

console.log('Kind equality comparison:');
await testWasmNoArgs('test_kind_eq.wasm', 'test_kind_eq', 1);
console.log('');

console.log('SubString from textbuf:');
await testWasmNoArgs('test_substr_from_buf.wasm', 'test_substr_from_buf', 1);
console.log('');

console.log('parse_julia_literal return type:');
await testWasmNoArgs('test_literal_type.wasm', 'test_literal_type', 1);
