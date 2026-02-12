import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();

async function test(wasmFile, funcName, input, expected) {
  try {
    const w = readFileSync(join(__dirname, wasmFile));
    const m = await rt.load(w, wasmFile);
    const s = await rt.jsToWasmString(input);
    const r = m.exports[funcName](s);
    const rval = typeof r === 'bigint' ? Number(r) : r;
    const pass = expected !== undefined ? rval === expected : true;
    console.log(`${pass ? 'OK ' : 'BAD'} ${funcName}("${input}") = ${rval}${expected !== undefined ? ` (expected ${expected})` : ''}`);
  } catch(e) {
    console.log(`ERR ${funcName}("${input}"): ${e.message}`);
    const lines = (e.stack||'').split('\n').filter(l => l.includes('wasm-function'));
    for (const l of lines) console.log(`    ${l.trim()}`);
  }
}

// Test string length basics
await test("str_length.wasm", "str_length", "hello", 5);
await test("str_length.wasm", "str_length", "1", 1);

// Test SubString ncodeunits
await test("test_substring_len.wasm", "f3", "hello", 5);
await test("test_substring_len.wasm", "f3", "1", 1);

// Test eachindex iteration count
await test("test_count_indices.wasm", "count_indices", "hello", 5);
await test("test_count_indices.wasm", "count_indices", "1", 1);
await test("test_count_indices.wasm", "count_indices", "", 0);

// Test line_starts counting
await test("test_count_lines.wasm", "count_line_starts", "hello", 1);
await test("test_count_lines.wasm", "count_line_starts", "1", 1);
await test("test_count_lines.wasm", "count_line_starts", "a\nb", 2);
await test("test_count_lines.wasm", "count_line_starts", "", 1);
