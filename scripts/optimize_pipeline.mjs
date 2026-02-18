// PURE-4162: Optimize pipeline.wasm with Binaryen.js (production flags)
//
// Usage: node scripts/optimize_pipeline.mjs [input.wasm] [output.wasm]
//   Defaults: scripts/pipeline.wasm → scripts/pipeline-optimized.wasm
//
// This script uses binaryen.js with dart2wasm production optimization flags.
// The same optimization logic will run in the browser for self-hosting.

import binaryen from "binaryen";
import fs from "fs";
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

const inputPath = process.argv[2] || join(__dirname, "pipeline.wasm");
const outputPath = process.argv[3] || join(__dirname, "pipeline-optimized.wasm");

console.log("=== PURE-4162: Binaryen.js Pipeline Optimization ===\n");

const bytes = fs.readFileSync(inputPath);
console.log(`Input:  ${inputPath}`);
console.log(`Size:   ${bytes.length} bytes (${(bytes.length/1024/1024).toFixed(2)} MB)\n`);

// Load module and set WasmGC features
const mod = binaryen.readBinary(new Uint8Array(bytes));
const features = binaryen.Features.GC |
    binaryen.Features.ReferenceTypes |
    binaryen.Features.Multivalue |
    binaryen.Features.NontrappingFPToInt |
    binaryen.Features.ExceptionHandling |
    binaryen.Features.BulkMemory |
    binaryen.Features.SignExt;
mod.setFeatures(features);

// CRITICAL: Disable exact reference types for browser compatibility
binaryen.setPassArgument("no-exact", "true");
binaryen.setClosedWorld(true);
binaryen.setTrapsNeverHappen(true);

// Production optimization: dart2wasm multi-pass sequence
// type-unfinalizing → -Os → type-ssa+gufa → -Os → type-merging → -Os → type-finalizing+minimize-rec-groups
const start = Date.now();

mod.runPasses(["type-unfinalizing"]);
binaryen.setOptimizeLevel(2);
binaryen.setShrinkLevel(1);
mod.optimize();
mod.runPasses(["type-ssa", "gufa"]);
mod.optimize();
mod.runPasses(["type-merging"]);
mod.optimize();
mod.runPasses(["type-finalizing", "minimize-rec-groups"]);

const elapsed = Date.now() - start;
const out = mod.emitBinary();
mod.dispose();

// Save optimized output
fs.writeFileSync(outputPath, Buffer.from(out));

const reduction = ((1 - out.length / bytes.length) * 100).toFixed(1);
console.log(`Output: ${outputPath}`);
console.log(`Size:   ${out.length} bytes (${(out.length/1024).toFixed(0)} KB)`);
console.log(`Reduction: ${reduction}%`);
console.log(`Time:   ${elapsed}ms\n`);

// Quick correctness check
console.log("--- Correctness Verification ---");
const importObject = { Math: { pow: Math.pow } };
const { instance } = await WebAssembly.instantiate(out, importObject);
const e = instance.exports;

let pass = 0, total = 0;
function check(name, actual, expected) {
    total++;
    const ok = typeof expected === 'bigint' ? actual === expected : actual === expected;
    if (ok) { pass++; console.log(`  CORRECT: ${name} = ${actual}`); }
    else { console.log(`  FAIL: ${name} got ${actual}, expected ${expected}`); }
}

check("test_add_1_1 (1+1)", e.test_add_1_1(), 2);
check("test_sub_1 (Int64<:Number)", e.test_sub_1(), 1);
check("test_sub_2 (Int64≮String)", e.test_sub_2(), 0);
check("test_isect_1 (Int64∩Number=Int64)", e.test_isect_1(), 1);
check("test_isect_2 (Int64∩String=⊥)", e.test_isect_2(), 1);
check("pipeline_add(1,1)", e.pipeline_add(1n, 1n), 2n);
check("pipeline_add(10,20)", e.pipeline_add(10n, 20n), 30n);
check("pipeline_mul(2,3)", e.pipeline_mul(2n, 3n), 6n);
check("pipeline_mul(7,8)", e.pipeline_mul(7n, 8n), 56n);
check("pipeline_sin(0.0)", e.pipeline_sin(0.0), 0.0);

console.log(`\nResult: ${pass}/${total} CORRECT`);
if (pass === total) console.log("ALL CORRECT — optimization preserves correctness ✓");
process.exit(pass === total ? 0 : 1);
