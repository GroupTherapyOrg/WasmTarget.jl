// PURE-7012: Function call expansion test — sin(1.0), abs(-5), sqrt(4.0)
//
// Tests:
//   1. "sin(1.0)" → 0.8414709848078965 (Float64 math function)
//   2. "abs(-5)" → 5 (Int64 math function)
//   3. "sqrt(4.0)" → 2.0 (Float64 math function)
//   4. "1+1" → 2 (regression check — arithmetic still works)
//   5. "2*3" → 6 (regression check)
//   6. "9/3" → 3.0 (regression check)
//
// Ground truth: native Julia results (verified before writing this test).

import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WASM_PATH = join(__dirname, '..', 'output', 'eval_julia.wasm');

console.log("=== PURE-7012: Function Call Expansion Test ===\n");

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

// Helper: full pipeline string → inner module → call export → result
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
    const innerExports = Object.keys(inner.instance.exports);

    // Detect function call pattern: name(arg)
    const funcMatch = expr.match(/^(\w+)\((.+)\)$/);
    if (funcMatch) {
        const funcName = funcMatch[1];
        const argStr = funcMatch[2].trim();
        const fn = inner.instance.exports[funcName];
        if (!fn) throw new Error(`No export "${funcName}" in inner module (has: ${innerExports.join(', ')})`);
        // Determine arg type: contains '.' → f64 (Number), else i64 (BigInt)
        const isFloat = argStr.includes('.');
        const arg = isFloat ? parseFloat(argStr) : BigInt(parseInt(argStr, 10));
        const result = fn(arg);
        return { result: Number(result), innerBytes, isFloat };
    }

    // Binary operator path
    const opMatch = expr.match(/([+\-*/])/);
    if (!opMatch) throw new Error(`Cannot parse expression "${expr}"`);
    const op = opMatch[1];
    const fn = inner.instance.exports[op];
    if (!fn) throw new Error(`No export "${op}" in inner module (has: ${innerExports.join(', ')})`);

    const parts = expr.split(opMatch[0]);
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
    // PURE-7012: Function calls (NEW)
    { expr: "sin(1.0)",  expected: 0.8414709848078965, approx: true, label: "sin(Float64) — PURE-7012 NEW" },
    { expr: "abs(-5)",   expected: 5,                  approx: false, label: "abs(Int64) — PURE-7012 NEW" },
    { expr: "sqrt(4.0)", expected: 2.0,                approx: false, label: "sqrt(Float64) — PURE-7012 NEW" },
    // Regression checks
    { expr: "1+1",       expected: 2,    approx: false, label: "Int64 + (regression)" },
    { expr: "2*3",       expected: 6,    approx: false, label: "Int64 * (regression)" },
    { expr: "9/3",       expected: 3.0,  approx: false, label: "Float64 / (regression)" },
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
console.log("PURE-7012: ALL CORRECT — function call expansion verified");
