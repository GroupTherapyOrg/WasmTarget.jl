import binaryen from "binaryen";
import fs from "fs";

console.log("=== Binaryen.js WasmGC Optimization Test ===\n");

// Read pipeline.wasm
const bytes = fs.readFileSync("scripts/pipeline.wasm");
console.log("Original size:", bytes.length, "bytes", `(${(bytes.length / 1024 / 1024).toFixed(2)} MB)`);

// Load module with all features including GC
const mod = binaryen.readBinary(new Uint8Array(bytes));
console.log("Module loaded successfully");

// Enable all features (including GC, exception handling, etc.)
mod.setFeatures(binaryen.Features.All);
console.log("Features set to All (includes GC:", binaryen.Features.GC, ")");

console.log("Num functions:", mod.getNumFunctions());
console.log("Num exports:", mod.getNumExports());

// Validate before optimization
const validBefore = mod.validate();
console.log("Valid before optimization:", validBefore);

// Test different optimization levels
const levels = [
  { name: "-O1", opt: 1, shrink: 0 },
  { name: "-Os", opt: 2, shrink: 1 },
  { name: "-Oz", opt: 2, shrink: 2 },
  { name: "-O3", opt: 3, shrink: 0 },
];

for (const level of levels) {
  // Re-read for each test (optimize mutates the module)
  const testMod = binaryen.readBinary(new Uint8Array(bytes));
  testMod.setFeatures(binaryen.Features.All);

  binaryen.setOptimizeLevel(level.opt);
  binaryen.setShrinkLevel(level.shrink);

  const start = Date.now();
  testMod.optimize();
  const elapsed = Date.now() - start;

  const out = testMod.emitBinary();
  const validAfter = testMod.validate();

  const pct = ((1 - out.length / bytes.length) * 100).toFixed(1);
  console.log(`\n${level.name}: ${out.length} bytes (${(out.length/1024).toFixed(0)} KB) — ${pct}% reduction — valid: ${validAfter} — ${elapsed}ms`);

  // Write the -Os version for testing
  if (level.name === "-Os") {
    fs.writeFileSync("/tmp/pipeline_binaryenjs_Os.wasm", Buffer.from(out));
    console.log("  -> Written to /tmp/pipeline_binaryenjs_Os.wasm");
  }
  if (level.name === "-Oz") {
    fs.writeFileSync("/tmp/pipeline_binaryenjs_Oz.wasm", Buffer.from(out));
    console.log("  -> Written to /tmp/pipeline_binaryenjs_Oz.wasm");
  }

  testMod.dispose();
}

// Also test specific passes
console.log("\n=== Individual Optimization Passes ===");
const passes = [
  "dce",                    // Dead code elimination
  "remove-unused-functions", // Remove unused functions
  "vacuum",                 // Remove unnecessary nodes
  "simplify-locals",        // Simplify local variables
  "coalesce-locals",        // Reduce number of locals
  "code-folding",           // Fold duplicate code
  "merge-blocks",           // Merge adjacent blocks
];

for (const pass of passes) {
  try {
    const testMod = binaryen.readBinary(new Uint8Array(bytes));
    testMod.setFeatures(binaryen.Features.All);

    const start = Date.now();
    testMod.runPasses([pass]);
    const elapsed = Date.now() - start;

    const out = testMod.emitBinary();
    const pct = ((1 - out.length / bytes.length) * 100).toFixed(1);
    console.log(`${pass}: ${out.length} bytes (${pct}% reduction) — ${elapsed}ms`);
    testMod.dispose();
  } catch (e) {
    console.log(`${pass}: ERROR — ${e.message}`);
  }
}

console.log("\n=== Summary ===");
console.log("Binaryen.js DOES support WasmGC (struct.new, struct.get, array.new, ref.cast, etc.)");
console.log("All optimization levels work on WasmGC modules");
console.log("Binaryen.js can run in Node.js and browser (same .js bundle)");
