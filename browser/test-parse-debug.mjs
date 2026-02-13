// Test individual parsestmt functions to narrow the bug
import { readFileSync } from 'fs';

const runtimeCode = readFileSync('WasmTarget.jl/browser/wasmtarget-runtime.js', 'utf-8');
const WRT = new Function(runtimeCode + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const wasmBytes = readFileSync('WasmTarget.jl/browser/parsestmt.wasm');
const pa = await rt.load(wasmBytes, 'parsestmt');

const exports = pa.exports;

// Create a string "1" in wasm
const s = await rt.jsToWasmString("1");
console.log("String created:", s);

// List available exports
const exportNames = Object.keys(exports).filter(k => typeof exports[k] === 'function');
console.log("Total exports:", exportNames.length);
console.log("Key exports:", exportNames.slice(0, 30));

// Try calling ParseStream (func 3) — creates the stream
// ParseStream takes: (ref null 6) (ref null 1) i64 (ref null 2) -> (ref null 29)
// We need to figure out the arguments

// Try calling parse_expr_string with error handling
try {
    const result = exports.parse_expr_string(s);
    console.log("parse_expr_string PASS:", result);
} catch(e) {
    console.log("parse_expr_string FAIL:", e.constructor.name, e.message);
    // Try to get exception payload
    if (e instanceof WebAssembly.Exception) {
        console.log("  WebAssembly.Exception caught");
        console.log("  is:", e.is ? "has is()" : "no is()");
    }
}
