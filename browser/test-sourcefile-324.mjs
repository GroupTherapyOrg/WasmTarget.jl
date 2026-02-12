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

// Test SourceFile constructor (should return first_line=1 for all inputs)
await test("test_source_file.wasm", "make_source_file", "1", 1);
await test("test_source_file.wasm", "make_source_file", "hello", 1);
await test("test_source_file.wasm", "make_source_file", "a\nb", 1);
await test("test_source_file.wasm", "make_source_file", "", 1);
