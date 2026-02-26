// PURE-7008: JS execution bridge for eval_julia_to_bytes_vec
//
// Reusable helpers for the eval_julia WASM pipeline:
//   1. Encode JS string → WasmGC byte vector
//   2. Extract WasmGC byte vector → JS Uint8Array
//   3. Instantiate inner WASM module from extracted bytes
//   4. Full pipeline: string → parse → extract → instantiate → execute → result
//
// Used by: browser playground (PURE-7009), CLI tests, any JS consumer.

import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

// --- Exported helpers ---

// Encode a JS string as a WasmGC Vector{UInt8} using the outer module's exports.
// Returns an opaque WasmGC reference (externref).
export function jsToWasmBytes(exports, str) {
    const vec = exports['make_byte_vec'](str.length);
    for (let i = 0; i < str.length; i++) {
        exports['set_byte_vec!'](vec, i + 1, str.charCodeAt(i)); // 1-indexed
    }
    return vec;
}

// Extract a WasmGC Vector{UInt8} into a JS Uint8Array.
// Uses eval_julia_result_length and eval_julia_result_byte exports.
export function extractWasmBytes(exports, wasmVec) {
    const len = exports['eval_julia_result_length'](wasmVec);
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
        bytes[i] = exports['eval_julia_result_byte'](wasmVec, i + 1); // 1-indexed
    }
    return bytes;
}

// Instantiate an inner WASM module from raw bytes.
// Returns { instance, module } from WebAssembly.instantiate.
export async function executeInnerModule(wasmBytes, imports = {}) {
    if (!(wasmBytes instanceof Uint8Array) || wasmBytes.length < 8) {
        throw new Error(`Invalid WASM bytes: expected Uint8Array with >=8 bytes, got ${wasmBytes?.length ?? 0}`);
    }
    // Validate WASM magic number
    if (wasmBytes[0] !== 0x00 || wasmBytes[1] !== 0x61 ||
        wasmBytes[2] !== 0x73 || wasmBytes[3] !== 0x6d) {
        const magic = Array.from(wasmBytes.slice(0, 4)).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ');
        throw new Error(`Invalid WASM magic: ${magic} (expected 0x00 0x61 0x73 0x6d)`);
    }
    return await WebAssembly.instantiate(wasmBytes, imports);
}

// Full pipeline: JS string → eval_julia_to_bytes_vec → extract → instantiate → call export → result.
//
// Parameters:
//   exports  — the outer WASM module's exports (must have make_byte_vec, set_byte_vec!,
//              eval_julia_to_bytes_vec, eval_julia_result_length, eval_julia_result_byte)
//   expr     — Julia expression string (e.g. "1+1")
//   imports  — imports for the inner WASM module (default: { Math: { pow: Math.pow } })
//
// Returns: { result: BigInt|number, innerExports: string[], innerBytes: Uint8Array }
export async function evalJulia(exports, expr, imports = { Math: { pow: Math.pow } }) {
    // Step 1: Encode expression string → WasmGC byte vector
    const inputVec = jsToWasmBytes(exports, expr);

    // Step 2: Call eval_julia_to_bytes_vec → WasmGC Vector{UInt8} of inner WASM bytes
    const resultVec = exports['eval_julia_to_bytes_vec'](inputVec);

    // Step 3: Extract inner WASM bytes to JS
    const innerBytes = extractWasmBytes(exports, resultVec);

    // Step 4: Instantiate inner module
    const { instance } = await executeInnerModule(innerBytes, imports);
    const innerExports = Object.keys(instance.exports);

    // Step 5: Find and call the operator export
    // Inner modules export a single function named after the operator ("+", "-", "*", "/")
    const opMatch = expr.match(/([+\-*/])/);
    if (!opMatch) {
        throw new Error(`Cannot find operator in expression "${expr}"`);
    }
    const op = opMatch[1];
    const fn = instance.exports[op];
    if (!fn) {
        throw new Error(`No export "${op}" in inner module (has: ${innerExports.join(', ')})`);
    }

    // Parse operands — split on the operator
    // PURE-7011: Detect Float64 (contains '.') and use Number instead of BigInt
    const parts = expr.split(opMatch[0]);
    const isFloat = expr.includes('.');
    let left, right;
    if (isFloat) {
        left = parseFloat(parts[0].trim());
        right = parseFloat(parts[1].trim());
    } else {
        left = BigInt(parseInt(parts[0].trim(), 10));
        right = BigInt(parseInt(parts[1].trim(), 10));
    }

    const result = fn(left, right);
    return { result, innerExports, innerBytes, isFloat };
}

// Load the outer WASM module from a file path.
// Returns the WebAssembly instance exports.
export async function loadOuterModule(wasmPath, imports = { Math: { pow: Math.pow } }) {
    const wasmBytes = await readFile(wasmPath);
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    return instance.exports;
}

// --- Self-test (when run directly) ---

async function selfTest() {
    const __dirname = dirname(fileURLToPath(import.meta.url));
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');

    console.log("=== PURE-7008: JS execution bridge self-test ===\n");

    // Load outer module
    let outerExports;
    try {
        const wasmBytes = await readFile(wasmPath);
        console.log(`Outer module: ${wasmBytes.length} bytes`);
        outerExports = await loadOuterModule(wasmPath);
        const fnCount = Object.keys(outerExports).filter(k => typeof outerExports[k] === 'function').length;
        console.log(`Exports: ${fnCount} functions\n`);
    } catch (e) {
        console.error(`Failed to load outer module: ${e.message}`);
        process.exit(1);
    }

    // Test cases (native Julia ground truth)
    const testCases = [
        { expr: "1+1",     expected: 2 },
        { expr: "2+3",     expected: 5 },
        { expr: "10-3",    expected: 7 },
        { expr: "2.0+3.0", expected: 5.0 },  // PURE-7011: Float64
    ];

    let pass = 0;
    let fail = 0;

    for (const { expr, expected } of testCases) {
        try {
            const { result, innerBytes } = await evalJulia(outerExports, expr);
            const resultNum = Number(result);
            if (resultNum === expected) {
                console.log(`  evalJulia("${expr}") = ${resultNum} — CORRECT (${innerBytes.length} byte inner module)`);
                pass++;
            } else {
                console.log(`  evalJulia("${expr}") = ${resultNum} — WRONG (expected ${expected})`);
                fail++;
            }
        } catch (e) {
            console.log(`  evalJulia("${expr}") = ERROR: ${e.message}`);
            fail++;
        }
    }

    // Test extractWasmBytes independently
    console.log("\n--- extractWasmBytes test ---");
    try {
        const inputVec = jsToWasmBytes(outerExports, "1+1");
        const resultVec = outerExports['eval_julia_to_bytes_vec'](inputVec);
        const bytes = extractWasmBytes(outerExports, resultVec);
        const hasWasmMagic = bytes[0] === 0x00 && bytes[1] === 0x61 && bytes[2] === 0x73 && bytes[3] === 0x6d;
        console.log(`  extractWasmBytes: ${bytes.length} bytes, WASM magic: ${hasWasmMagic ? 'YES' : 'NO'}`);
        if (hasWasmMagic) pass++; else fail++;
    } catch (e) {
        console.log(`  extractWasmBytes: ERROR — ${e.message}`);
        fail++;
    }

    // Test executeInnerModule independently
    console.log("\n--- executeInnerModule test ---");
    try {
        const inputVec = jsToWasmBytes(outerExports, "2+3");
        const resultVec = outerExports['eval_julia_to_bytes_vec'](inputVec);
        const bytes = extractWasmBytes(outerExports, resultVec);
        const { instance } = await executeInnerModule(bytes, { Math: { pow: Math.pow } });
        const exports = Object.keys(instance.exports);
        console.log(`  executeInnerModule: instantiated OK, exports: [${exports.join(', ')}]`);
        pass++;
    } catch (e) {
        console.log(`  executeInnerModule: ERROR — ${e.message}`);
        fail++;
    }

    // Test error handling
    console.log("\n--- Error handling ---");
    try {
        await executeInnerModule(new Uint8Array([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]), {});
        console.log("  Invalid magic: WRONG (should have thrown)");
        fail++;
    } catch (e) {
        console.log(`  Invalid magic rejected: ${e.message.includes('Invalid WASM magic') ? 'CORRECT' : 'WRONG — ' + e.message}`);
        if (e.message.includes('Invalid WASM magic')) pass++; else fail++;
    }

    console.log(`\n=== RESULT: ${pass}/${pass + fail} tests passed ===`);
    if (fail > 0) {
        console.log(`${fail} failure(s)`);
        process.exit(1);
    }
    console.log("PURE-7008: PASS — all bridge helpers work correctly");
}

selfTest().catch(e => { console.error(e); process.exit(1); });
