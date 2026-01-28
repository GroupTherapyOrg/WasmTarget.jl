/**
 * Node.js test for WasmTargetRuntime string conversion (PURE-201 + PURE-202).
 *
 * Run: node test-strings-node.mjs
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

let passed = 0;
let failed = 0;

function assert(condition, msg) {
    if (condition) {
        console.log(`  PASS: ${msg}`);
        passed++;
    } else {
        console.log(`  FAIL: ${msg}`);
        failed++;
    }
}

console.log("WasmTargetRuntime - String Conversion Tests\n");

const rt = new WasmTargetRuntime();

// Test 1: Basic ASCII string roundtrip
console.log("1. ASCII roundtrip");
{
    const input = "hello";
    const wasmStr = await rt.jsToWasmString(input);
    assert(wasmStr !== null && wasmStr !== undefined, "jsToWasmString returns a value");
    const output = await rt.wasmToJsString(wasmStr);
    assert(output === input, `"${input}" -> wasm -> "${output}"`);
}

// Test 2: Empty string
console.log("2. Empty string");
{
    const input = "";
    const wasmStr = await rt.jsToWasmString(input);
    const output = await rt.wasmToJsString(wasmStr);
    assert(output === input, `empty string roundtrip`);
}

// Test 3: Single character
console.log("3. Single character");
{
    const input = "x";
    const wasmStr = await rt.jsToWasmString(input);
    const output = await rt.wasmToJsString(wasmStr);
    assert(output === input, `single char roundtrip`);
}

// Test 4: Julia-like code string
console.log("4. Julia code string");
{
    const input = "f(x) = x^2 + 1";
    const wasmStr = await rt.jsToWasmString(input);
    const output = await rt.wasmToJsString(wasmStr);
    assert(output === input, `Julia code: "${output}"`);
}

// Test 5: Special characters
console.log("5. Special characters");
{
    const input = "a\tb\nc\r\n\"d'e\\f";
    const wasmStr = await rt.jsToWasmString(input);
    const output = await rt.wasmToJsString(wasmStr);
    assert(output === input, `special chars roundtrip`);
}

// Test 6: Unicode - accented characters
console.log("6. Unicode BMP characters");
{
    const input = "café résumé naïve";
    const wasmStr = await rt.jsToWasmString(input);
    const output = await rt.wasmToJsString(wasmStr);
    assert(output === input, `BMP unicode: "${output}"`);
}

// Test 7: Unicode - emoji (supplementary plane)
console.log("7. Unicode emoji (surrogate pairs)");
{
    const input = "Hello 🌍!";
    const wasmStr = await rt.jsToWasmString(input);
    const output = await rt.wasmToJsString(wasmStr);
    assert(output === input, `emoji: "${output}"`);
}

// Test 8: Unicode - CJK
console.log("8. Unicode CJK");
{
    const input = "日本語テスト";
    const wasmStr = await rt.jsToWasmString(input);
    const output = await rt.wasmToJsString(wasmStr);
    assert(output === input, `CJK: "${output}"`);
}

// Test 9: Mixed emoji and ASCII
console.log("9. Mixed emoji sequence");
{
    const input = "a🎉b🚀c";
    const wasmStr = await rt.jsToWasmString(input);
    const output = await rt.wasmToJsString(wasmStr);
    assert(output === input, `mixed emoji: "${output}"`);
}

// Test 10: String bridge is lazy-loaded and reused
console.log("10. String bridge caching");
{
    assert(rt._stringBridge !== null, "bridge loaded after first use");
    const bridge = rt._stringBridge;
    await rt.jsToWasmString("test");
    assert(rt._stringBridge === bridge, "bridge reused (not reloaded)");
}

// Test 11: Cross-module compatibility
console.log("11. Cross-module string passing");
try {
    const wasmBytes = await readFile("/tmp/parsestmt_m1b.wasm");
    const parser = await rt.load(wasmBytes, "parsestmt");
    const wasmStr = await rt.jsToWasmString("1 + 1");

    // parsestmt expects (i32 type_tag, array<i32> string)
    // Type tag 0 for Expr. This may trap due to missing runtime support,
    // but should NOT throw a type error (structural typing compatibility).
    try {
        parser.exports.parsestmt(0, wasmStr);
        assert(true, "parsestmt accepted WasmGC string (no type error)");
    } catch (e) {
        // A trap (null deref, etc.) is OK — it means the type was accepted
        const isTypeError = e.message.includes("type");
        assert(!isTypeError, `parsestmt accepted string type (trap: ${e.message})`);
    }
} catch (err) {
    console.log(`  SKIP: ${err.message}`);
}

// Summary
console.log(`\n${"=".repeat(40)}`);
console.log(`Results: ${passed} passed, ${failed} failed`);
console.log(failed === 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED");
process.exit(failed > 0 ? 1 : 0);
