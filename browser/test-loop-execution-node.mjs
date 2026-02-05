/**
 * Node.js test: Verify while-loop execution (PURE-302).
 *
 * Compiles simple_sum(n::Int32) = (s=0; i=1; while i<=n; s+=i; i+=1; end; s)
 * and verifies it produces correct results when executed.
 *
 * Run: node test-loop-execution-node.mjs
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

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

console.log("PURE-302: While-Loop Execution Test\n");

// Load simple_sum.wasm
const wasmPath = join(__dirname, "simple_sum.wasm");
const wasmBytes = await readFile(wasmPath);
const imports = { Math: { pow: Math.pow } };
const { instance } = await WebAssembly.instantiate(wasmBytes, imports);

const simple_sum = instance.exports.simple_sum;
assert(typeof simple_sum === "function", "simple_sum is exported as a function");

// Test cases: simple_sum(n) should return 1+2+...+n = n*(n+1)/2
const testCases = [
    { input: 0, expected: 0, desc: "simple_sum(0) = 0" },
    { input: 1, expected: 1, desc: "simple_sum(1) = 1" },
    { input: 5, expected: 15, desc: "simple_sum(5) = 15 (1+2+3+4+5)" },
    { input: 10, expected: 55, desc: "simple_sum(10) = 55" },
    { input: 100, expected: 5050, desc: "simple_sum(100) = 5050" },
    { input: -1, expected: 0, desc: "simple_sum(-1) = 0 (loop never enters)" },
];

for (const { input, expected, desc } of testCases) {
    try {
        const result = simple_sum(input);
        assert(result === expected, `${desc} → got ${result}`);
    } catch (e) {
        assert(false, `${desc} → TRAP: ${e.message || e}`);
    }
}

// Summary
console.log(`\n${"=".repeat(50)}`);
console.log(`Results: ${passed} passed, ${failed} failed`);
console.log(failed === 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED");

if (failed === 0) {
    console.log("\nPURE-302 Status: PASS");
    console.log("- While-loops EXECUTE correctly (not just validate)");
    console.log("- Loop iteration produces correct accumulation");
    console.log("- Edge cases handled: n=0, n=-1, n=100");
}

process.exit(failed > 0 ? 1 : 0);
