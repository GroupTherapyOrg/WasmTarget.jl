// PURE-325 Agent 22: Second-level cursor iteration tests
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rtCode = readFileSync(join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rtCode + '\nreturn WasmTargetRuntime;')();

async function testWasm(filename, funcName, input, expected) {
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

console.log('=== Second-Level Cursor Isolation Tests ===');
console.log('');

console.log('Test 5: test_call_child_count (Green Reverse iteration of call node children)');
await testWasm('test_call_child_count.wasm', 'test_call_child_count', '1+1', 3);
await testWasm('test_call_child_count.wasm', 'test_call_child_count', 'x+y', 3);
await testWasm('test_call_child_count.wasm', 'test_call_child_count', '(1)', 3);
console.log('');

console.log('Test 6: test_red_child_count (Red Reverse iteration of call node children)');
await testWasm('test_red_child_count.wasm', 'test_red_child_count', '1+1', 3);
await testWasm('test_red_child_count.wasm', 'test_red_child_count', 'x+y', 3);
await testWasm('test_red_child_count.wasm', 'test_red_child_count', '(1)', 3);
console.log('');

console.log('Test 7: test_red_nontrivia_count (Red + filter, like parseargs!)');
await testWasm('test_red_nontrivia_count.wasm', 'test_red_nontrivia_count', '1+1', 3);
await testWasm('test_red_nontrivia_count.wasm', 'test_red_nontrivia_count', '(1)', 1);
console.log('');

console.log('Test 8: test_first_child_span (first child byte_span via Green cursor)');
await testWasm('test_first_child_span.wasm', 'test_first_child_span', '1+1', 1);
