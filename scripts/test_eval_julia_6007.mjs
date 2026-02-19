// PURE-6007: Test eval_julia_wasm WASM module in Node.js
// Verifies: eval_julia("1+1") returns 2 (matches PURE-6003 ground truth)
//
// Pipeline:
//   1. Load eval_julia_6007.wasm module
//   2. Create WasmGC string "1+1" via string bridge
//   3. Call eval_julia_wasm("1+1") → WasmGC String of bytes
//   4. Extract bytes via eval_julia_result_length + eval_julia_result_byte
//   5. WebAssembly.instantiate(bytes) → inner module
//   6. Call +(1n, 1n) → result; verify === 2n

import { readFile } from 'fs/promises';

// String bridge module (creates WasmGC array<i32> strings)
const STRING_BRIDGE_BASE64 = "AGFzbQEAAAABJgZgAnx8AXxPAF5/AWABfwFjAWADYwF/fwBgAmMBfwF/YAFjAQF/AgwBBE1hdGgDcG93AAADBQQCAwQFBy8EB3N0cl9uZXcAAQxzdHJfc2V0Y2hhciEAAghzdHJfY2hhcgADB3N0cl9sZW4ABAosBAcAIAD7BwELDgAgACABQQFrIAL7DgELDAAgACABQQFr+wsBCwYAIAD7Dws=";

const NATIVE_GROUND_TRUTH = {
    "eval_julia_wasm(\"1+1\")": "returns bytes of +(Int64,Int64) → when executed, 2",
    "test_parse_1plus1()": 1,
    "test_parse_1plus1_nargs()": 3,
    "test_parse_42()": 1,
    "test_eval_julia_wasm_len()": 90,   // 90 bytes for +(Int64,Int64) module
    "test_eval_julia_wasm_magic0()": 0,  // First WASM byte: 0x00
    "test_eval_julia_wasm_magic1()": 97, // Second WASM byte: 0x61 = 'a'
};

async function main() {
    console.log("=== PURE-6007: eval_julia WASM Module Test ===\n");
    console.log("Ground truth: eval_julia_native(\"1+1\") = 2 (from PURE-6003)\n");

    // Step 1: Load module
    console.log("--- Step 1: Load eval_julia_6007.wasm ---");
    const wasmBytes = await readFile('/tmp/eval_julia_6007.wasm');
    const imports = { Math: { pow: Math.pow } };

    let instance;
    try {
        const result = await WebAssembly.instantiate(wasmBytes, imports);
        instance = result.instance;
        console.log("  Module loaded: YES");
        const exportNames = Object.keys(instance.exports).filter(k => typeof instance.exports[k] === 'function');
        console.log(`  Exports: ${exportNames.length} functions`);
    } catch (e) {
        console.log("  Module loaded: FAIL - " + e.message);
        process.exit(1);
    }
    console.log();

    // Step 2: String bridge for creating WasmGC strings
    console.log("--- Step 2: String bridge ---");
    const bridgeBytes = Buffer.from(STRING_BRIDGE_BASE64, "base64");
    const bridgeResult = await WebAssembly.instantiate(bridgeBytes, imports);
    const bridge = bridgeResult.instance.exports;

    function jsToWasmString(str) {
        const codepoints = [...str];
        const wasmStr = bridge.str_new(codepoints.length);
        for (let i = 0; i < codepoints.length; i++) {
            bridge["str_setchar!"](wasmStr, i + 1, codepoints[i].codePointAt(0));
        }
        return wasmStr;
    }

    const str_1plus1 = jsToWasmString("1+1");
    console.log("  String bridge loaded: YES");
    console.log("  Created WasmGC string '1+1': YES");
    console.log();

    // Step 3: Test parse functions (regression check)
    console.log("--- Step 3: Parse regression tests ---");
    let all_parse_pass = true;
    for (const [name, expected] of [
        ["test_parse_1plus1", 1],
        ["test_parse_1plus1_nargs", 3],
        ["test_parse_42", 1],
    ]) {
        try {
            const result = instance.exports[name]();
            const pass = result === expected;
            if (!pass) all_parse_pass = false;
            console.log(`  ${name}() = ${result} (expected ${expected}) → ${pass ? "CORRECT" : "WRONG"}`);
        } catch (e) {
            all_parse_pass = false;
            console.log(`  ${name}(): TRAP - ${e.message}`);
        }
    }
    console.log();

    // Step 4: Test eval_julia_wasm internal helpers (no-arg wrappers)
    console.log("--- Step 4: eval_julia_wasm no-arg tests ---");
    let wasm_len = -1;
    let wasm_magic0 = -1;
    let wasm_magic1 = -1;
    for (const [name, expected] of [
        ["test_eval_julia_wasm_len", 90],
        ["test_eval_julia_wasm_magic0", 0],
        ["test_eval_julia_wasm_magic1", 97],
    ]) {
        try {
            const result = instance.exports[name]();
            const pass = result === expected;
            console.log(`  ${name}() = ${result} (expected ${expected}) → ${pass ? "CORRECT" : "WRONG"}`);
            if (name === "test_eval_julia_wasm_len") wasm_len = result;
            if (name === "test_eval_julia_wasm_magic0") wasm_magic0 = result;
            if (name === "test_eval_julia_wasm_magic1") wasm_magic1 = result;
        } catch (e) {
            console.log(`  ${name}(): TRAP - ${e.message}`);
        }
    }
    console.log();

    // Step 5: Call eval_julia_wasm("1+1") and extract bytes
    console.log("--- Step 5: eval_julia_wasm(\"1+1\") → extract bytes ---");
    let wasm_bytes_extracted = null;
    let bytes_len = -1;
    try {
        const vec_ref = instance.exports.eval_julia_wasm(str_1plus1);
        console.log("  eval_julia_wasm called: YES (no trap)");

        // Get length
        const len = instance.exports.eval_julia_result_length(vec_ref);
        bytes_len = len;
        console.log(`  eval_julia_result_length = ${len} (expected 90)`);

        // Extract bytes
        if (len > 0) {
            wasm_bytes_extracted = new Uint8Array(len);
            for (let i = 1; i <= len; i++) {
                wasm_bytes_extracted[i-1] = instance.exports.eval_julia_result_byte(vec_ref, i);
            }
            console.log(`  Extracted ${len} bytes`);
            const magic = [...wasm_bytes_extracted.slice(0, 8)].map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ');
            console.log(`  First 8 bytes: ${magic}`);
            const validWasm = wasm_bytes_extracted[0] === 0x00 && wasm_bytes_extracted[1] === 0x61 &&
                              wasm_bytes_extracted[2] === 0x73 && wasm_bytes_extracted[3] === 0x6d;
            console.log(`  WASM magic valid: ${validWasm}`);
        }
    } catch (e) {
        console.log(`  eval_julia_wasm: TRAP - ${e.message}`);
    }
    console.log();

    // Step 6: Instantiate inner module and execute
    console.log("--- Step 6: Instantiate inner module → execute +(1n, 1n) ---");
    let final_result = null;
    let is_correct = false;
    if (wasm_bytes_extracted !== null) {
        try {
            const innerResult = await WebAssembly.instantiate(wasm_bytes_extracted.buffer, { Math: { pow: Math.pow } });
            console.log("  Inner module instantiated: YES");
            const plus_fn = innerResult.instance.exports['+'];
            if (plus_fn) {
                const result = plus_fn(1n, 1n);
                final_result = result;
                is_correct = result === 2n;
                console.log(`  +(1n, 1n) = ${result} (expected 2n) → ${is_correct ? "CORRECT" : "WRONG"}`);
            } else {
                console.log("  ERROR: '+' export not found in inner module");
                const exports = Object.keys(innerResult.instance.exports);
                console.log(`  Available exports: ${exports.join(', ')}`);
            }
        } catch (e) {
            console.log(`  Inner module: ERROR - ${e.message}`);
        }
    } else {
        console.log("  Skipped (no bytes extracted)");
    }
    console.log();

    // Summary
    console.log("=== Summary ===");
    console.log(`  1. Module loads: PASS`);
    console.log(`  2. Parse functions: ${all_parse_pass ? "PASS" : "FAIL"}`);
    console.log(`  3. eval_julia_wasm helper tests: ${wasm_len === 90 && wasm_magic0 === 0 && wasm_magic1 === 97 ? "PASS" : "FAIL"}`);
    console.log(`  4. Bytes extracted: ${bytes_len === 90 ? "PASS (90 bytes)" : "FAIL"}`);
    console.log(`  5. eval_julia("1+1") = ${final_result} → ${is_correct ? "CORRECT (= 2)" : "WRONG or FAILED"}`);

    if (is_correct) {
        console.log("\n✓ PURE-6007: eval_julia(\"1+1\") = 2 — CORRECT");
    } else {
        console.log("\n✗ PURE-6007: NOT CORRECT yet");
        process.exit(1);
    }
}

main().catch(e => { console.error(e); process.exit(1); });
