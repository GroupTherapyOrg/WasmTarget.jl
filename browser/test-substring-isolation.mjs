import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const s = await rt.jsToWasmString("hello");

// Test 1: codeunit
try {
  const w = readFileSync(join(__dirname, "test_codeunit.wasm"));
  const m = await rt.load(w, "t1");
  const r = m.exports.f1(s);
  console.log("codeunit('hello', 1) =", r, "(expected: 104)");
} catch(e) {
  console.log("codeunit FAIL:", e.message);
}

// Test 2: SubString
try {
  const w = readFileSync(join(__dirname, "test_substring.wasm"));
  const m = await rt.load(w, "t2");
  const r = m.exports.f2(s);
  console.log("SubString('hello') =", r, typeof r);
} catch(e) {
  console.log("SubString FAIL:", e.message);
}

// Test 3: ncodeunits
try {
  const w = readFileSync(join(__dirname, "test_substring_len.wasm"));
  const m = await rt.load(w, "t3");
  const r = m.exports.f3(s);
  console.log("ncodeunits(SubString('hello')) =", r, "(expected: 5)");
} catch(e) {
  console.log("ncodeunits FAIL:", e.message);
}
