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

console.log('=== Runtime Kind Diagnostic Tests ===');
console.log('');

console.log('kind(head) value (constant-folded):');
await testWasmNoArgs('test_kind_value_rt.wasm', 'test_kind_value_rt', 44);
console.log('');

console.log('k == K"Integer" comparison (constant-folded):');
await testWasmNoArgs('test_integer_check_rt.wasm', 'test_integer_check_rt', 44);
console.log('');

console.log('parse_julia_literal branch (RUNTIME — 46 IR statements):');
const result = await testWasmNoArgs('test_literal_branch_rt.wasm', 'test_literal_branch_rt', 1);
if (!result) {
  console.log('  Branch decoding:');
  console.log('  1 = matched Float, 2 = Float32, 3 = Char, 4 = String/CmdString, 5 = Bool');
  console.log('  10 = matched Integer (CORRECT), 11 = BinInt/OctInt/HexInt');
  console.log('  -1 = Symbol (identifier), -2 = Nothing (syntax_kind), -3 = Bool check');
  console.log('  -4 = Float64, -5 = Char, -6 = String, -999 = unknown type');
}
