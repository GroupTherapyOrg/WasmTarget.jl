// PURE-325 Agent 22: Cursor isolation tests
// Tests progressive complexity of cursor operations
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

console.log('=== Cursor Isolation Tests ===');
console.log('');

// Test 1: output length (simplest — just parse and return array length)
console.log('Test 1: test_output_length (parse + return output.length)');
await testWasm('test_output_length.wasm', 'test_output_length', '1', 3);
await testWasm('test_output_length.wasm', 'test_output_length', '1+1', 6);
await testWasm('test_output_length.wasm', 'test_output_length', 'x', 3);
console.log('');

// Test 2: top node span (parse + access struct field)
console.log('Test 2: test_top_node_span (parse + GreenTreeCursor + struct field access)');
await testWasm('test_top_node_span.wasm', 'test_top_node_span', '1', 1);
await testWasm('test_top_node_span.wasm', 'test_top_node_span', '1+1', 4);
await testWasm('test_top_node_span.wasm', 'test_top_node_span', 'x', 1);
console.log('');

// Test 3: first child position (parse + cursor + first iteration step)
console.log('Test 3: test_first_child_position (parse + Reverse iteration first step)');
await testWasm('test_first_child_position.wasm', 'test_first_child_position', '1', 2);
await testWasm('test_first_child_position.wasm', 'test_first_child_position', '1+1', 5);
await testWasm('test_first_child_position.wasm', 'test_first_child_position', 'x', 2);
console.log('');

// Test 4: child count (parse + full iteration)
console.log('Test 4: test_child_count (parse + full Reverse iteration)');
await testWasm('test_child_count.wasm', 'test_child_count', '1', 1);
await testWasm('test_child_count.wasm', 'test_child_count', '1+1', 1);
await testWasm('test_child_count.wasm', 'test_child_count', 'x', 1);
