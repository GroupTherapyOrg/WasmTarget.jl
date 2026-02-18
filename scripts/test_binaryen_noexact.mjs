// Test binaryen.js with custom descriptors disabled to avoid 'exact' heap types
import binaryen from "binaryen";
import fs from "fs";
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

console.log("=== Binaryen.js: Test without exact types ===\n");

const bytes = fs.readFileSync(join(__dirname, "pipeline.wasm"));
console.log("Original size:", bytes.length, "bytes");

// Try enabling only GC + friends but NOT custom descriptors
const mod = binaryen.readBinary(new Uint8Array(bytes));
const features = binaryen.Features.GC |
    binaryen.Features.ReferenceTypes |
    binaryen.Features.Multivalue |
    binaryen.Features.NontrappingFPToInt |
    binaryen.Features.ExceptionHandling |
    binaryen.Features.BulkMemory |
    binaryen.Features.SignExt;
mod.setFeatures(features);
console.log("Features (no custom descriptors):", features);

// Check available pass arguments
console.log("Looking for exact/descriptors settings...");
// Try setting --no-exact via pass argument
binaryen.setPassArgument("no-exact", "true");

binaryen.setOptimizeLevel(2);
binaryen.setShrinkLevel(1);
mod.optimize();
const out = mod.emitBinary();
console.log("Optimized size:", out.length, "bytes");

fs.writeFileSync("/tmp/pipeline_binaryenjs_noexact.wasm", Buffer.from(out));
console.log("Written to /tmp/pipeline_binaryenjs_noexact.wasm");
mod.dispose();

// Test if it loads
try {
    const importObject = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(out, importObject);
    console.log("Instantiated successfully!");
    const r = instance.exports.test_add_1_1();
    console.log("test_add_1_1:", r, r === 2 ? "CORRECT" : "FAIL");
} catch (e) {
    console.log("Instantiation failed:", e.message.substring(0, 200));
}
