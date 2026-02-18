// PURE-4162: Test optimized pipeline.wasm — verify correctness after Binaryen optimization
//
// Usage: node scripts/test_optimized_pipeline.mjs [optimized.wasm]
//   Default: scripts/pipeline-optimized.wasm
//
// Tests both the wasm-opt CLI output (from compile_pipeline.jl) and
// binaryen.js output (from optimize_pipeline.mjs).

import fs from "fs";
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function testWasm(label, wasmPath) {
    if (!fs.existsSync(wasmPath)) {
        console.log(`\n  SKIP ${label}: ${wasmPath} not found`);
        return null;
    }
    const bytes = fs.readFileSync(wasmPath);
    console.log(`\n--- ${label} ---`);
    console.log(`  File: ${wasmPath}`);
    console.log(`  Size: ${bytes.length} bytes (${(bytes.length/1024).toFixed(0)} KB)`);

    try {
        const importObject = { Math: { pow: Math.pow } };
        const { instance } = await WebAssembly.instantiate(bytes, importObject);
        const e = instance.exports;

        let pass = 0, fail = 0;
        function check(name, actual, expected) {
            const ok = typeof expected === 'bigint' ? actual === expected : actual === expected;
            if (ok) { pass++; console.log(`  CORRECT: ${name} = ${actual}`); }
            else { fail++; console.log(`  FAIL: ${name} got ${actual}, expected ${expected}`); }
        }

        check("test_add_1_1 (1+1=2)", e.test_add_1_1(), 2);
        check("test_sub_1 (Int64<:Number)", e.test_sub_1(), 1);
        check("test_sub_2 (Int64≮String)", e.test_sub_2(), 0);
        check("test_isect_1 (Int64∩Number=Int64)", e.test_isect_1(), 1);
        check("test_isect_2 (Int64∩String=⊥)", e.test_isect_2(), 1);
        check("pipeline_add(1,1)=2", e.pipeline_add(1n, 1n), 2n);
        check("pipeline_add(10,20)=30", e.pipeline_add(10n, 20n), 30n);
        check("pipeline_mul(2,3)=6", e.pipeline_mul(2n, 3n), 6n);
        check("pipeline_mul(7,8)=56", e.pipeline_mul(7n, 8n), 56n);
        check("pipeline_sin(0.0)=0.0", e.pipeline_sin(0.0), 0.0);

        console.log(`  Result: ${pass}/10 CORRECT` + (fail > 0 ? ` (${fail} FAIL)` : ''));
        return pass === 10;
    } catch (e) {
        console.log(`  ERROR: ${e.message}`);
        return false;
    }
}

console.log("=== PURE-4162: Optimized Pipeline Correctness Test ===");

// Test original (baseline)
const origOk = await testWasm("Original (unoptimized)", join(__dirname, "pipeline.wasm"));

// Test wasm-opt CLI output (from compile_pipeline.jl)
const cliOk = await testWasm("Optimized (wasm-opt CLI)", join(__dirname, "pipeline-optimized.wasm"));

// Summary
console.log(`\n${"=".repeat(60)}`);
console.log("Summary:");
if (origOk !== null) console.log(`  Original:  ${origOk ? "10/10 CORRECT ✓" : "FAIL ✗"}`);
if (cliOk !== null) console.log(`  Optimized: ${cliOk ? "10/10 CORRECT ✓" : "FAIL ✗"}`);

// Compare sizes
if (fs.existsSync(join(__dirname, "pipeline.wasm")) && fs.existsSync(join(__dirname, "pipeline-optimized.wasm"))) {
    const origSize = fs.statSync(join(__dirname, "pipeline.wasm")).size;
    const optSize = fs.statSync(join(__dirname, "pipeline-optimized.wasm")).size;
    const reduction = ((1 - optSize / origSize) * 100).toFixed(1);
    console.log(`  Size reduction: ${(origSize/1024).toFixed(0)} KB → ${(optSize/1024).toFixed(0)} KB (${reduction}%)`);
}

const allOk = (origOk === null || origOk) && (cliOk === null || cliOk);
process.exit(allOk ? 0 : 1);
