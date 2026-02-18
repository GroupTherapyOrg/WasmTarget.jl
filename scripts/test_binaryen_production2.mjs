// PURE-2002: Test binaryen.js with production optimizations
import binaryen from "binaryen";
import fs from "fs";
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

const bytes = fs.readFileSync(join(__dirname, "pipeline.wasm"));
console.log("Original:", bytes.length, "bytes\n");

function optimizeWith(name, configFn) {
    const mod = binaryen.readBinary(new Uint8Array(bytes));
    const features = binaryen.Features.GC |
        binaryen.Features.ReferenceTypes |
        binaryen.Features.Multivalue |
        binaryen.Features.NontrappingFPToInt |
        binaryen.Features.ExceptionHandling |
        binaryen.Features.BulkMemory |
        binaryen.Features.SignExt;
    mod.setFeatures(features);
    binaryen.setPassArgument("no-exact", "true");

    configFn(mod);

    const start = Date.now();
    mod.optimize();
    const elapsed = Date.now() - start;
    const out = mod.emitBinary();
    mod.dispose();
    console.log(`${name}: ${out.length} bytes (${(out.length/1024).toFixed(0)} KB) — ${((1-out.length/bytes.length)*100).toFixed(1)}% reduction — ${elapsed}ms`);
    return out;
}

// Test 1: Simple -Os
optimizeWith("-Os (simple)", (mod) => {
    binaryen.setOptimizeLevel(2);
    binaryen.setShrinkLevel(1);
});

// Test 2: -Os with closed-world + traps-never-happen
optimizeWith("-Os + closed-world", (mod) => {
    binaryen.setOptimizeLevel(2);
    binaryen.setShrinkLevel(1);
    binaryen.setClosedWorld(true);
    binaryen.setTrapsNeverHappen(true);
});

// Test 3: -O3 with closed-world + traps-never-happen
optimizeWith("-O3 + closed-world", (mod) => {
    binaryen.setOptimizeLevel(3);
    binaryen.setShrinkLevel(0);
    binaryen.setClosedWorld(true);
    binaryen.setTrapsNeverHappen(true);
});

// Test 4: -Oz with closed-world + traps-never-happen
const out4 = optimizeWith("-Oz + closed-world", (mod) => {
    binaryen.setOptimizeLevel(2);
    binaryen.setShrinkLevel(2);
    binaryen.setClosedWorld(true);
    binaryen.setTrapsNeverHappen(true);
});

// Test 5: Multi-pass with pass sequence (dart2wasm-style)
{
    const mod = binaryen.readBinary(new Uint8Array(bytes));
    const features = binaryen.Features.GC |
        binaryen.Features.ReferenceTypes |
        binaryen.Features.Multivalue |
        binaryen.Features.NontrappingFPToInt |
        binaryen.Features.ExceptionHandling |
        binaryen.Features.BulkMemory |
        binaryen.Features.SignExt;
    mod.setFeatures(features);
    binaryen.setPassArgument("no-exact", "true");
    binaryen.setClosedWorld(true);
    binaryen.setTrapsNeverHappen(true);

    const start = Date.now();
    // Run specific passes manually, like dart2wasm does
    try {
        mod.runPasses(["type-unfinalizing"]);
        binaryen.setOptimizeLevel(2); binaryen.setShrinkLevel(1);
        mod.optimize();
        mod.runPasses(["type-ssa", "gufa"]);
        mod.optimize();
        mod.runPasses(["type-merging"]);
        mod.optimize();
        mod.runPasses(["type-finalizing", "minimize-rec-groups"]);
    } catch(e) {
        console.log("Multi-pass error:", e.message);
    }
    const elapsed = Date.now() - start;
    const out = mod.emitBinary();
    mod.dispose();
    console.log(`Multi-pass (production): ${out.length} bytes (${(out.length/1024).toFixed(0)} KB) — ${((1-out.length/bytes.length)*100).toFixed(1)}% reduction — ${elapsed}ms`);

    // Verify correctness of production output
    fs.writeFileSync("/tmp/pipeline_binaryenjs_prod.wasm", Buffer.from(out));

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
    console.log(`Production correctness: ${pass}/10 CORRECT`);
}
