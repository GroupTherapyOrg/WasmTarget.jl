// PURE-2002: Test that binaryen-optimized pipeline.wasm still produces correct results
import fs from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function testWasm(label, wasmPath) {
    if (!fs.existsSync(wasmPath)) {
        console.log(`  SKIP ${label}: file not found`);
        return;
    }
    const bytes = fs.readFileSync(wasmPath);
    console.log(`\n--- ${label} (${bytes.length} bytes / ${(bytes.length/1024).toFixed(0)} KB) ---`);

    try {
        const importObject = { Math: { pow: Math.pow } };
        const { instance } = await WebAssembly.instantiate(bytes, importObject);
        const exports = instance.exports;

        let pass = 0, fail = 0;
        function check(name, actual, expected) {
            const ok = typeof expected === 'bigint' ? actual === expected : actual === expected;
            if (ok) { pass++; }
            else { fail++; console.log(`    FAIL: ${name} got ${actual}, expected ${expected}`); }
        }

        check("test_add_1_1", exports.test_add_1_1(), 2);
        check("test_sub_1", exports.test_sub_1(), 1);
        check("test_sub_2", exports.test_sub_2(), 0);
        check("test_isect_1", exports.test_isect_1(), 1);
        check("test_isect_2", exports.test_isect_2(), 1);
        check("pipeline_add(1,1)", exports.pipeline_add(1n, 1n), 2n);
        check("pipeline_add(10,20)", exports.pipeline_add(10n, 20n), 30n);
        check("pipeline_mul(2,3)", exports.pipeline_mul(2n, 3n), 6n);
        check("pipeline_mul(7,8)", exports.pipeline_mul(7n, 8n), 56n);
        check("pipeline_sin(0.0)", exports.pipeline_sin(0.0), 0.0);

        console.log(`  Result: ${pass}/10 CORRECT` + (fail > 0 ? ` (${fail} FAIL)` : ''));
    } catch (e) {
        console.log(`  ERROR: ${e.message}`);
    }
}

console.log("=== PURE-2002: Optimized Pipeline Correctness Test ===");

await testWasm("Original", join(__dirname, "pipeline.wasm"));
await testWasm("wasm-opt -Os (CLI)", "/tmp/pipeline_optimized.wasm");
await testWasm("binaryen.js -Os", "/tmp/pipeline_binaryenjs_Os.wasm");
await testWasm("binaryen.js -Oz", "/tmp/pipeline_binaryenjs_Oz.wasm");
