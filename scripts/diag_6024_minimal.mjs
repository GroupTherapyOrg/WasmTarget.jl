// Minimal diagnostic: just load module and try simplest possible call
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    const imports = { Math: { pow: Math.pow } };

    console.log("Loading module...");
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    console.log("Module loaded.");

    // Check make_byte_vec type
    console.log("\nmake_byte_vec type:", typeof instance.exports['make_byte_vec']);

    // Try with explicit integer
    console.log("\nCalling make_byte_vec(3)...");
    try {
        const result = instance.exports['make_byte_vec'](3);
        console.log("Result:", result, "type:", typeof result);

        // Try set_byte_vec!
        console.log("\nCalling set_byte_vec!(result, 1, 49)...");
        const r2 = instance.exports['set_byte_vec!'](result, 1, 49);
        console.log("set_byte_vec! returned:", r2);
    } catch (e) {
        console.error("Error:", e.message);
        console.error("Stack:", e.stack?.split('\n').slice(0, 5).join('\n'));
    }

    // Try eval_julia_result_length with null
    console.log("\nCalling eval_julia_result_length with various args...");
    try {
        // Create a vec first
        const vec = instance.exports['make_byte_vec'](3);
        console.log("vec:", vec);
        const len = instance.exports['eval_julia_result_length'](vec);
        console.log("length:", len);
    } catch (e) {
        console.error("Error:", e.message);
        console.error("Stack:", e.stack?.split('\n').slice(0, 5).join('\n'));
    }
}

main().catch(e => { console.error(e); process.exit(1); });
