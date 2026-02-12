import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const w = readFileSync(join(__dirname, "parsestmt.wasm"));
const pa = await rt.load(w, "parsestmt");

// The crash is in #SourceFile#8 (func 16) when it accesses SubString.string
// Let's test what we can about the data flow

// First: what type 32 looks like (SubString)
// struct { ref null 1 (string array), i64 (offset), i64 (ncodeunits) }

// Test: Can we get the exports list and identify any that return a SubString?
const exports = Object.keys(pa.exports).filter(k => typeof pa.exports[k] === 'function');
console.log("Total exports:", exports.length);

// The #SourceFile#8 takes: (i32, i64, i64, i32, ref null 32) -> ref null 35
// We need to construct a valid SubString to call it directly
// But we can't easily construct WasmGC structs from JS

// Let's try another angle: compile a simple test function that creates SubString
// and calls the same SourceFile code, but WITHIN the parsestmt module

// Actually, let's look at what happens if we try to call parse_expr_string
// with an empty string vs longer strings
const inputs = ["", "1", "ab", "hello world", "a\nb\nc"];
for (const input of inputs) {
  const s = await rt.jsToWasmString(input);
  try {
    const result = pa.exports.parse_expr_string(s);
    console.log(`Input "${input.replace(/\n/g, '\\n')}": PASS (${result})`);
  } catch(e) {
    console.log(`Input "${input.replace(/\n/g, '\\n')}": FAIL: ${e.message}`);
    const lines = (e.stack||'').split('\n').filter(l => l.includes('wasm-function'));
    if (lines.length > 0) console.log(`  Stack: ${lines.map(l => l.trim()).join(' -> ')}`);
  }
}

// Key question: does the error change with input length?
// If index is always out of bounds regardless of input, it's likely offset is huge
// If only short strings fail, it might be a bounds issue with small arrays
