// Test production-optimized pipeline.wasm for correctness
import fs from 'fs';

const files = [
    { name: "Original", path: "scripts/pipeline.wasm" },
    { name: "wasm-opt -Os (simple)", path: "/tmp/pipeline_optimized.wasm" },
    { name: "wasm-opt -Os (production)", path: "/tmp/pipeline_production.wasm" },
    { name: "binaryen.js -Os", path: "/tmp/pipeline_binaryenjs_noexact.wasm" },
];

console.log("=== Size Comparison ===\n");
for (const f of files) {
    if (fs.existsSync(f.path)) {
        const sz = fs.statSync(f.path).size;
        console.log(`${f.name}: ${sz} bytes (${(sz/1024).toFixed(0)} KB)`);
    }
}

console.log("\n=== Correctness Tests ===");

for (const f of files) {
    if (!fs.existsSync(f.path)) { console.log(`\n${f.name}: SKIP`); continue; }
    const bytes = fs.readFileSync(f.path);
    try {
        const importObject = { Math: { pow: Math.pow } };
        const { instance } = await WebAssembly.instantiate(bytes, importObject);
        const e = instance.exports;
        let pass = 0;
        function check(actual, expected) {
            const ok = typeof expected === 'bigint' ? actual === expected : actual === expected;
            if (ok) pass++;
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
        console.log(`\n${f.name}: ${pass}/10 CORRECT`);
    } catch (e) {
        console.log(`\n${f.name}: ERROR — ${e.message.substring(0, 200)}`);
    }
}
