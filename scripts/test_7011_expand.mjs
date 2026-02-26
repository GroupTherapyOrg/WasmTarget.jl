// PURE-7011: Expanded arithmetic test — Int64 *, - and Float64 + division
//
// Tests:
//   1. "2*3" → 6     (Int64 multiplication — already worked from PURE-7007a)
//   2. "10-3" → 7    (Int64 multi-digit subtraction)
//   3. "6*7" → 42    (Int64 multiplication)
//   4. "2.0+3.0" → 5.0  (Float64 addition — NEW type path)
//   5. "9/3" → 3.0   (Float64 division — was trapping, now uses Float64 precompute)
//   6. "1+1" → 2     (Int64 addition — regression check)
//   7. "3.0*4.0" → 12.0 (Float64 multiplication)
//   8. "10.0/3.0" → 3.333... (Float64 division, non-exact)
//
// Ground truth: native Julia results (verified before writing this test).
// All values are EXACT except 10.0/3.0 which uses approximate comparison.

import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WASM_PATH = join(__dirname, '..', 'output', 'eval_julia.wasm');

console.log("=== PURE-7011: Expanded Arithmetic Test ===\n");

// Load outer module
const wasmBytes = await readFile(WASM_PATH);
console.log(`Outer module: ${wasmBytes.length} bytes`);
const { instance } = await WebAssembly.instantiate(wasmBytes, { Math: { pow: Math.pow } });
const e = instance.exports;
const fnCount = Object.keys(e).filter(k => typeof e[k] === 'function').length;
console.log(`Exports: ${fnCount} functions\n`);

// Helper: encode JS string → WasmGC Vector{UInt8}
function jsToWasmBytes(str) {
    const vec = e['make_byte_vec'](str.length);
    for (let i = 0; i < str.length; i++) {
        e['set_byte_vec!'](vec, i + 1, str.charCodeAt(i));
    }
    return vec;
}

// Helper: extract WasmGC Vector{UInt8} → JS Uint8Array
function extractWasmBytes(wasmVec) {
    const len = e['eval_julia_result_length'](wasmVec);
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
        bytes[i] = e['eval_julia_result_byte'](wasmVec, i + 1);
    }
    return bytes;
}

// Helper: full pipeline string → result
async function evalJulia(expr) {
    const inputVec = jsToWasmBytes(expr);
    const resultVec = e['eval_julia_to_bytes_vec'](inputVec);
    const innerBytes = extractWasmBytes(resultVec);

    // Validate WASM magic
    if (innerBytes[0] !== 0x00 || innerBytes[1] !== 0x61 ||
        innerBytes[2] !== 0x73 || innerBytes[3] !== 0x6d) {
        throw new Error(`Bad WASM magic: ${Array.from(innerBytes.slice(0, 4)).map(b => '0x' + b.toString(16)).join(' ')}`);
    }

    // Instantiate inner module
    const inner = await WebAssembly.instantiate(innerBytes, { Math: { pow: Math.pow } });
    const exports = Object.keys(inner.instance.exports);

    // Detect operator
    const opMatch = expr.match(/([+\-*/])/);
    const op = opMatch[1];
    const fn = inner.instance.exports[op];
    if (!fn) throw new Error(`No export "${op}" in inner module (has: ${exports.join(', ')})`);

    // Parse operands — Float64 if has '.' or division
    const parts = expr.split(op === '-' ? '-' : op === '+' ? '+' : op === '*' ? '*' : '/');
    const isFloat = expr.includes('.') || op === '/';
    let left, right;
    if (isFloat) {
        left = parseFloat(parts[0].trim());
        right = parseFloat(parts[1].trim());
    } else {
        left = BigInt(parseInt(parts[0].trim(), 10));
        right = BigInt(parseInt(parts[1].trim(), 10));
    }

    const result = fn(left, right);
    return { result: Number(result), innerBytes, isFloat };
}

// Test cases with native Julia ground truth
const testCases = [
    // Int64 (already working — regression checks)
    { expr: "1+1",       expected: 2,    approx: false, label: "Int64 + (regression)" },
    { expr: "2*3",       expected: 6,    approx: false, label: "Int64 * (PURE-7011)" },
    { expr: "10-3",      expected: 7,    approx: false, label: "Int64 - multi-digit (PURE-7011)" },
    { expr: "6*7",       expected: 42,   approx: false, label: "Int64 * (PURE-7011)" },
    { expr: "2+3",       expected: 5,    approx: false, label: "Int64 + (regression)" },
    { expr: "8-3",       expected: 5,    approx: false, label: "Int64 - (regression)" },
    // Float64 (NEW — PURE-7011)
    { expr: "2.0+3.0",   expected: 5.0,  approx: false, label: "Float64 + (PURE-7011 NEW)" },
    { expr: "9/3",       expected: 3.0,  approx: false, label: "Float64 / int operands (PURE-7011 NEW)" },
    { expr: "3.0*4.0",   expected: 12.0, approx: false, label: "Float64 * (PURE-7011 NEW)" },
    { expr: "2.0-1.0",   expected: 1.0,  approx: false, label: "Float64 - (PURE-7011 NEW)" },
    { expr: "10.0/3.0",  expected: 3.3333333333333335, approx: true, label: "Float64 / non-exact (PURE-7011 NEW)" },
    { expr: "6/2",       expected: 3.0,  approx: false, label: "Float64 / int simple (PURE-7011 NEW)" },
];

let pass = 0;
let fail = 0;

console.log("--- Test results ---");
for (const { expr, expected, approx, label } of testCases) {
    try {
        const { result, innerBytes, isFloat } = await evalJulia(expr);
        const typeStr = isFloat ? "Float64" : "Int64";
        const matches = approx
            ? Math.abs(result - expected) < 1e-14
            : result === expected;
        if (matches) {
            console.log(`  CORRECT: "${expr}" = ${result} (${typeStr}, ${innerBytes.length}B) — ${label}`);
            pass++;
        } else {
            console.log(`  WRONG:   "${expr}" = ${result}, expected ${expected} (${typeStr}) — ${label}`);
            fail++;
        }
    } catch (err) {
        console.log(`  ERROR:   "${expr}" — ${err.message} — ${label}`);
        fail++;
    }
}

console.log(`\n=== RESULT: ${pass}/${pass + fail} CORRECT ===`);
if (fail > 0) {
    console.log(`${fail} failure(s)`);
    process.exit(1);
}
console.log("PURE-7011: ALL CORRECT — arithmetic expansion verified");
