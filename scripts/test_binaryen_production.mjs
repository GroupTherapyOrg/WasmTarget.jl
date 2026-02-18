// PURE-2002: Test binaryen.js with dart2wasm production flags
import binaryen from "binaryen";
import fs from "fs";
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

const bytes = fs.readFileSync(join(__dirname, "pipeline.wasm"));
console.log("Original:", bytes.length, "bytes\n");

// Dart2wasm production optimization using binaryen.js
const mod = binaryen.readBinary(new Uint8Array(bytes));
const features = binaryen.Features.GC |
    binaryen.Features.ReferenceTypes |
    binaryen.Features.Multivalue |
    binaryen.Features.NontrappingFPToInt |
    binaryen.Features.ExceptionHandling |
    binaryen.Features.BulkMemory |
    binaryen.Features.SignExt;
mod.setFeatures(features);

// Disable exact types for browser compatibility
binaryen.setPassArgument("no-exact", "true");

// Production settings
binaryen.setClosedWorld(true);
binaryen.setTrapsNeverHappen(true);

// Run dart2wasm-style pass sequence
const passes = [
    "type-unfinalizing",
    "Os",              // -Os
    "type-ssa",
    "gufa",
    "Os",              // -Os again
    "type-merging",
    "Os",              // -Os again
    "type-finalizing",
    "minimize-rec-groups",
];

console.log("Running production pass sequence...");
const start = Date.now();
try {
    mod.runPasses(passes);
} catch (e) {
    console.log("Error running passes:", e.message);
    // Fallback: just use optimize()
    console.log("Falling back to mod.optimize()...");
    const mod2 = binaryen.readBinary(new Uint8Array(bytes));
    mod2.setFeatures(features);
    binaryen.setOptimizeLevel(2);
    binaryen.setShrinkLevel(1);
    mod2.optimize();
    const out2 = mod2.emitBinary();
    console.log("Fallback size:", out2.length, "bytes");
    mod2.dispose();
}
const elapsed = Date.now() - start;

const out = mod.emitBinary();
console.log(`Production optimized: ${out.length} bytes (${(out.length/1024).toFixed(0)} KB) — ${elapsed}ms`);
console.log(`Reduction: ${((1 - out.length/bytes.length)*100).toFixed(1)}%`);
mod.dispose();

// Verify correctness
const importObject = { Math: { pow: Math.pow } };
const { instance } = await WebAssembly.instantiate(out, importObject);
const e = instance.exports;
let pass = 0;
function check(actual, expected) {
    const ok = typeof expected === 'bigint' ? actual === expected : actual === expected;
    if (ok) pass++;
    else console.log(`  FAIL: got ${actual}, expected ${expected}`);
}
check(e.test_add_1_1(), 2);
check(e.test_sub_1(), 1);
check(e.test_sub_2(), 0);
check(e.test_isect_1(), 1);
check(e.test_isect_2(), 1);
check(e.pipeline_add(1n, 1n), 2n);
check(e.pipeline_add(10n, 20n), 30n);
check(e.pipeline_mul(2n, 3n), 6n);
check(e.pipeline_mul(7n, 8n), 56n);
check(e.pipeline_sin(0.0), 0.0);
console.log(`Correctness: ${pass}/10 CORRECT`);
