// PURE-6024 Diagnostic: Test each pipeline step individually
// Isolate which step hits unreachable

import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-6024 Step-by-Step Diagnostic ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const e = instance.exports;

    // List all exports
    const funcExports = Object.keys(e).filter(k => typeof e[k] === 'function');
    console.log(`Exports (${funcExports.length}):`);
    for (const name of funcExports.slice(0, 30)) {
        console.log(`  ${name}`);
    }
    if (funcExports.length > 30) console.log(`  ... and ${funcExports.length - 30} more`);
    console.log();

    // Step 1: make_byte_vec
    console.log("--- Step 1: make_byte_vec(3) ---");
    try {
        const vec = e['make_byte_vec'](3);
        console.log(`  PASS: returned ${vec} (type: ${typeof vec})`);
    } catch (err) {
        console.log(`  FAIL: ${err.message}`);
        return;
    }

    // Step 2: set_byte_vec!
    console.log("--- Step 2: set_byte_vec!(vec, 1, 65) ---");
    try {
        const vec = e['make_byte_vec'](3);
        e['set_byte_vec!'](vec, 1, 49);  // '1'
        e['set_byte_vec!'](vec, 2, 43);  // '+'
        e['set_byte_vec!'](vec, 3, 49);  // '1'
        console.log(`  PASS: set 3 bytes '1+1'`);
    } catch (err) {
        console.log(`  FAIL: ${err.message}`);
        return;
    }

    // Step 3: Check if ParseStream export exists
    console.log("--- Step 3: ParseStream ---");
    if (typeof e['ParseStream'] === 'function') {
        console.log("  ParseStream export: YES");
        try {
            const vec = e['make_byte_vec'](3);
            e['set_byte_vec!'](vec, 1, 49);
            e['set_byte_vec!'](vec, 2, 43);
            e['set_byte_vec!'](vec, 3, 49);
            const ps = e['ParseStream'](vec);
            console.log(`  FAIL or PASS: returned ${ps} (type: ${typeof ps})`);
        } catch (err) {
            console.log(`  FAIL: ${err.message}`);
            // Print first line of stack
            if (err.stack) {
                const lines = err.stack.split('\n').slice(0, 5);
                for (const line of lines) console.log(`    ${line}`);
            }
        }
    } else {
        console.log("  ParseStream export: NO (not directly exported)");
    }

    // Step 4: Call full pipeline
    console.log("\n--- Step 4: eval_julia_to_bytes_vec('1+1') ---");
    try {
        const vec = e['make_byte_vec'](3);
        e['set_byte_vec!'](vec, 1, 49);
        e['set_byte_vec!'](vec, 2, 43);
        e['set_byte_vec!'](vec, 3, 49);
        const result = e['eval_julia_to_bytes_vec'](vec);
        console.log(`  PASS: returned ${result} (type: ${typeof result})`);
    } catch (err) {
        console.log(`  FAIL: ${err.message}`);
        if (err.stack) {
            const lines = err.stack.split('\n').slice(0, 8);
            for (const line of lines) console.log(`    ${line}`);
        }
    }

    // Step 5: Check what ParseStream actually takes
    console.log("\n--- Step 5: ParseStream signature analysis ---");
    // func 6 type 248: (param (ref null 6) (ref null 6) i64 (ref null 7)) (result (ref null 30))
    // This takes 4 params — it's NOT ParseStream(bytes::Vector{UInt8})!
    // It takes (ref null 6, ref null 6, i64, ref null 7) → (ref null 30)
    // ref null 6 is likely Vector{UInt8} struct
    // ref null 7 is another struct type
    // This is the INNER ParseStream constructor that eval_julia_to_bytes_vec calls
    console.log("  ParseStream (func 6) takes 4 params:");
    console.log("    param 0: (ref null 6)  — likely Vector{UInt8}");
    console.log("    param 1: (ref null 6)  — likely Vector{UInt8}");
    console.log("    param 2: i64           — some integer");
    console.log("    param 3: (ref null 7)  — some struct");
    console.log("  Can't call directly from JS with correct WasmGC types.");
    console.log("  The failure in eval_julia_to_bytes_vec → ParseStream is the issue.");
}

main().catch(e => { console.error(e); process.exit(1); });
