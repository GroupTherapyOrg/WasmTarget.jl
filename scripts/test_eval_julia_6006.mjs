// PURE-6006: Test eval_julia WASM module in Node.js
// 1. Module loads without errors
// 2. String bridge can create WasmGC strings
// 3. eval_julia_to_bytes can be called (expect trap at code_typed stage)
// 4. Individual parse functions execute

import { readFile } from 'fs/promises';

// String bridge module (creates WasmGC array<i32> strings)
const STRING_BRIDGE_BASE64 = "AGFzbQEAAAABJgZgAnx8AXxPAF5/AWABfwFjAWADYwF/fwBgAmMBfwF/YAFjAQF/AgwBBE1hdGgDcG93AAADBQQCAwQFBy8EB3N0cl9uZXcAAQxzdHJfc2V0Y2hhciEAAghzdHJfY2hhcgADB3N0cl9sZW4ABAosBAcAIAD7BwELDgAgACABQQFrIAL7DgELDAAgACABQQFr+wsBCwYAIAD7Dws=";

async function main() {
    console.log("=== PURE-6006: eval_julia WASM Module Test ===\n");

    // Step 1: Load module
    console.log("--- Step 1: Load module ---");
    const wasmBytes = await readFile('/tmp/eval_julia_6006.wasm');
    const imports = { Math: { pow: Math.pow } };

    let instance;
    try {
        const result = await WebAssembly.instantiate(wasmBytes, imports);
        instance = result.instance;
        console.log("  Module loaded: YES");
    } catch (e) {
        console.log("  Module loaded: FAIL - " + e.message);
        process.exit(1);
    }

    // Step 2: List exports
    const exportNames = Object.keys(instance.exports).filter(k => typeof instance.exports[k] === 'function');
    console.log(`  Exports: ${exportNames.length} functions`);
    console.log(`  Key exports: eval_julia_to_bytes, ParseStream, #parse!#73, build_tree, node_to_expr`);
    console.log();

    // Step 3: Initialize string bridge
    console.log("--- Step 2: String bridge ---");
    const bridgeBytes = Buffer.from(STRING_BRIDGE_BASE64, "base64");
    const bridgeResult = await WebAssembly.instantiate(bridgeBytes, imports);
    const bridge = bridgeResult.instance.exports;
    console.log("  String bridge loaded: YES");

    // Create a WasmGC string "1+1"
    function jsToWasmString(str) {
        const codepoints = [...str];
        const wasmStr = bridge.str_new(codepoints.length);
        for (let i = 0; i < codepoints.length; i++) {
            bridge["str_setchar!"](wasmStr, i + 1, codepoints[i].codePointAt(0));
        }
        return wasmStr;
    }

    const testStr = jsToWasmString("1+1");
    console.log("  Created WasmGC string '1+1': YES");
    console.log();

    // Step 4: Call eval_julia_to_bytes (expect trap at code_typed)
    console.log("--- Step 3: Call eval_julia_to_bytes('1+1') ---");
    try {
        const result = instance.exports.eval_julia_to_bytes(testStr);
        console.log("  Result: " + result);
        console.log("  eval_julia_to_bytes: EXECUTES (unexpected success!)");
    } catch (e) {
        if (e instanceof WebAssembly.RuntimeError) {
            console.log("  TRAP: " + e.message);
            // Expected — code_typed is stubbed
            console.log("  eval_julia_to_bytes: TRAPS (expected — code_typed is stubbed)");
        } else {
            console.log("  ERROR: " + e.message);
        }
    }
    console.log();

    // Step 5: Test parse functions (no-arg versions with hardcoded strings)
    console.log("--- Step 4: Test parse functions (native ground truth: 1=pass, 3=nargs, 1=int) ---");

    // test_parse_1plus1: returns 1 if parsestmt("1+1") is Expr with :call head
    try {
        const result = instance.exports.test_parse_1plus1();
        const pass = result === 1;
        console.log(`  test_parse_1plus1() = ${result} (expected 1) → ${pass ? "CORRECT" : "WRONG"}`);
    } catch (e) {
        console.log("  test_parse_1plus1(): TRAP - " + e.message);
    }

    // test_parse_1plus1_nargs: returns 3 (args: :+, 1, 1)
    try {
        const result = instance.exports.test_parse_1plus1_nargs();
        const pass = result === 3;
        console.log(`  test_parse_1plus1_nargs() = ${result} (expected 3) → ${pass ? "CORRECT" : "WRONG"}`);
    } catch (e) {
        console.log("  test_parse_1plus1_nargs(): TRAP - " + e.message);
    }

    // test_parse_42: returns 1 if parsestmt("42") is Integer
    try {
        const result = instance.exports.test_parse_42();
        const pass = result === 1;
        console.log(`  test_parse_42() = ${result} (expected 1) → ${pass ? "CORRECT" : "WRONG"}`);
    } catch (e) {
        console.log("  test_parse_42(): TRAP - " + e.message);
    }
    console.log();

    console.log("=== Summary ===");
    console.log("  1. Module loads: PASS");
    console.log("  2. String bridge: PASS");
    console.log("  3. eval_julia_to_bytes: Expected TRAP at code_typed");
    console.log("  4. Parse functions: See above");
}

main().catch(e => { console.error(e); process.exit(1); });
