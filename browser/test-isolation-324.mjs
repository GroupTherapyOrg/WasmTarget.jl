import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();

async function test(wasmFile, funcName, input) {
  try {
    const w = readFileSync(join(__dirname, wasmFile));
    const m = await rt.load(w, wasmFile);
    const s = await rt.jsToWasmString(input);
    const r = m.exports[funcName](s);
    console.log(`OK  ${funcName}("${input}") = ${r}`);
    return true;
  } catch(e) {
    console.log(`ERR ${funcName}("${input}"): ${e.message}`);
    if (e.stack) {
      const lines = e.stack.split('\n').filter(l => l.includes('wasm-function'));
      for (const l of lines) console.log(`    ${l.trim()}`);
    }
    return false;
  }
}

// Test simple SubString operations
await test("test_codeunit.wasm", "f1", "hello");
await test("test_substring.wasm", "f2", "hello");
await test("test_substring_len.wasm", "f3", "hello");
await test("test_ss_index.wasm", "get_first_char", "hello");
await test("test_ss_index.wasm", "get_first_char", "1");
