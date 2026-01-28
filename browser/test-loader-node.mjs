/**
 * Node.js test for WasmTargetRuntime module loader.
 *
 * Run: node --experimental-wasm-gc test-loader-node.mjs
 * (Node 25+ may not need the flag)
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

// Load the runtime (CommonJS module)
const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");

// Execute in a function scope to get the class
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

console.log("WasmTargetRuntime - Node.js Test\n");

// Test 1: Constructor
console.log("1. Constructor");
const rt = new WasmTargetRuntime();
assert(rt.modules instanceof Map, "modules is a Map");
assert(rt.modules.size === 0, "starts empty");

// Test 2: getImports
console.log("2. getImports");
const imports = rt.getImports();
assert(typeof imports.Math.pow === "function", "Math.pow provided");
assert(imports.Math.pow(2, 3) === 8, "Math.pow works correctly");

// Test 3: Load parsestmt.wasm from file
console.log("3. Load parsestmt.wasm");
try {
    const wasmPath = "/tmp/parsestmt_m1b.wasm";
    const wasmBytes = await readFile(wasmPath);
    const instance = await rt.load(wasmBytes, "parsestmt");

    assert(instance !== null, "instance created");
    assert(typeof instance.exports === "object", "has exports");

    const exportNames = Object.keys(instance.exports);
    assert(exportNames.length > 0, `has ${exportNames.length} exports`);

    // Check expected exports
    const expectedExports = ["parsestmt", "ParseStream", "Lexer", "parse_toplevel", "build_tree", "node_to_expr"];
    for (const name of expectedExports) {
        assert(typeof instance.exports[name] === "function", `export "${name}" is a function`);
    }

    // Test module registry
    assert(rt.get("parsestmt") === instance, 'registered as "parsestmt"');
    assert(rt.list().length === 1, "list() shows 1 module");
    assert(rt.list()[0] === "parsestmt", 'list() contains "parsestmt"');

    // Print all exports
    console.log("\n  All exports:");
    for (const name of exportNames) {
        console.log(`    ${name} (${typeof instance.exports[name]})`);
    }

} catch (err) {
    console.log(`  FAIL: ${err.message}`);
    failed++;
}

// Test 4: Load M2 lowering.wasm
console.log("\n4. Load lowering.wasm");
try {
    const wasmBytes = await readFile("/tmp/lowering_m2.wasm");
    const instance = await rt.load(wasmBytes, "lowering");
    assert(instance !== null, "lowering loaded");
    assert(rt.list().length === 2, "2 modules loaded");
    console.log(`  exports: [${Object.keys(instance.exports).join(", ")}]`);
} catch (err) {
    console.log(`  FAIL: ${err.message}`);
    failed++;
}

// Test 5: Error handling
console.log("\n5. Error handling");
try {
    rt.call("nonexistent", "func");
    assert(false, "should throw for missing module");
} catch (e) {
    assert(e.message.includes("not loaded"), "throws for missing module");
}

try {
    rt.call("parsestmt", "nonexistent_func");
    assert(false, "should throw for missing function");
} catch (e) {
    assert(e.message.includes("not an exported function"), "throws for missing function");
}

// Summary
console.log(`\n${"=".repeat(40)}`);
console.log(`Results: ${passed} passed, ${failed} failed`);
console.log(failed === 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED");
process.exit(failed > 0 ? 1 : 0);
