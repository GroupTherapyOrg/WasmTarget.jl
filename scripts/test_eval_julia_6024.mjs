// PURE-6024: Test eval_julia_to_bytes in Node.js
// Pipeline: Load module → string bridge → call eval_julia_to_bytes("1+1") → extract bytes → instantiate inner → execute
//
// Ground truth (verified natively with may_optimize=false):
//   eval_julia_native("1+1") = 2
//   eval_julia_native("2+3") = 5
//   eval_julia_native("10-3") = 7
//   eval_julia_native("6*7") = 42

import { readFile } from 'fs/promises';
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

// String bridge module (creates WasmGC array<i32> strings)
const STRING_BRIDGE_BASE64 = "AGFzbQEAAAABJgZgAnx8AXxPAF5/AWABfwFjAWADYwF/fwBgAmMBfwF/YAFjAQF/AgwBBE1hdGgDcG93AAADBQQCAwQFBy8EB3N0cl9uZXcAAQxzdHJfc2V0Y2hhciEAAghzdHJfY2hhcgADB3N0cl9sZW4ABAosBAcAIAD7BwELDgAgACABQQFrIAL7DgELDAAgACABQQFr+wsBCwYAIAD7Dws=";

async function main() {
    console.log("=== PURE-6024: eval_julia_to_bytes Node.js Test ===\n");

    // Step 1: Load eval_julia.wasm
    console.log("--- Step 1: Load eval_julia.wasm ---");
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    console.log(`  File size: ${wasmBytes.length} bytes`);

    const imports = { Math: { pow: Math.pow } };
    let instance;
    try {
        const result = await WebAssembly.instantiate(wasmBytes, imports);
        instance = result.instance;
        const funcExports = Object.keys(instance.exports).filter(k => typeof instance.exports[k] === 'function');
        console.log(`  Module LOADS: YES (${funcExports.length} function exports)`);

        // Check required exports
        const required = ['eval_julia_to_bytes', 'eval_julia_result_length', 'eval_julia_result_byte'];
        for (const name of required) {
            const found = typeof instance.exports[name] === 'function';
            console.log(`  Export '${name}': ${found ? 'YES' : 'MISSING'}`);
            if (!found) {
                console.log("  FAIL: Required export missing");
                process.exit(1);
            }
        }
    } catch (e) {
        console.log(`  Module LOAD FAIL: ${e.message}`);
        process.exit(1);
    }
    console.log();

    // Step 2: Initialize string bridge
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
    console.log("  String bridge: OK");
    console.log();

    // Step 3: Test eval_julia_to_bytes for each expression
    console.log("--- Step 3: eval_julia_to_bytes tests ---");
    const tests = [
        { expr: "1+1", op: "+", a: 1n, b: 1n, expected: 2n },
        { expr: "2+3", op: "+", a: 2n, b: 3n, expected: 5n },
        { expr: "10-3", op: "-", a: 10n, b: 3n, expected: 7n },
        { expr: "6*7", op: "*", a: 6n, b: 7n, expected: 42n },
    ];

    let allCorrect = true;
    for (const { expr, op, a, b, expected } of tests) {
        console.log(`\n  Testing: eval_julia_to_bytes("${expr}")`);
        try {
            // Create WasmGC string
            const wasmStr = jsToWasmString(expr);

            // Call eval_julia_to_bytes
            const vecRef = instance.exports.eval_julia_to_bytes(wasmStr);
            console.log(`    Call returned: ${vecRef} (type: ${typeof vecRef})`);

            // Extract bytes
            const len = instance.exports.eval_julia_result_length(vecRef);
            console.log(`    Byte length: ${len}`);

            if (len <= 0) {
                console.log(`    FAIL: No bytes returned`);
                allCorrect = false;
                continue;
            }

            const innerBytes = new Uint8Array(len);
            for (let i = 1; i <= len; i++) {
                innerBytes[i - 1] = instance.exports.eval_julia_result_byte(vecRef, i);
            }

            // Check WASM magic
            const magic = innerBytes[0] === 0x00 && innerBytes[1] === 0x61 &&
                          innerBytes[2] === 0x73 && innerBytes[3] === 0x6d;
            console.log(`    WASM magic valid: ${magic}`);

            if (!magic) {
                console.log(`    First 8 bytes: ${[...innerBytes.slice(0, 8)].map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ')}`);
                allCorrect = false;
                continue;
            }

            // Instantiate inner module
            const innerResult = await WebAssembly.instantiate(innerBytes.buffer, imports);
            const innerInstance = innerResult.instance;
            const innerExports = Object.keys(innerInstance.exports).filter(k => typeof innerInstance.exports[k] === 'function');
            console.log(`    Inner module: ${innerExports.length} exports (${innerExports.join(', ')})`);

            // Call the function
            const fn = innerInstance.exports[op];
            if (!fn) {
                console.log(`    FAIL: Export '${op}' not found`);
                allCorrect = false;
                continue;
            }

            const result = fn(a, b);
            const correct = result === expected;
            console.log(`    ${op}(${a}, ${b}) = ${result} (expected ${expected}) → ${correct ? "CORRECT" : "WRONG"}`);
            if (!correct) allCorrect = false;

        } catch (e) {
            console.log(`    ERROR: ${e.message}`);
            if (e.stack) {
                // Show first few lines of stack
                const lines = e.stack.split('\n').slice(0, 5);
                for (const line of lines) console.log(`      ${line}`);
            }
            allCorrect = false;
        }
    }

    // Summary
    console.log("\n=== Summary ===");
    if (allCorrect) {
        console.log("  ALL 4 CORRECT — eval_julia_to_bytes works in Node.js!");
    } else {
        console.log("  SOME TESTS FAILED");
        process.exit(1);
    }
}

main().catch(e => { console.error(e); process.exit(1); });
