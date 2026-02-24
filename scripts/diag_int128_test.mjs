// Test Int128 WASM functions against native Julia ground truth
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function loadWasm(name) {
    const path = join(__dirname, '..', 'output', `test_int128_${name}.wasm`);
    const bytes = await readFile(path);
    const { instance } = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
    return instance;
}

async function main() {
    console.log("=== Int128 WASM Tests ===\n");

    // Test 1: roundtrip
    console.log("--- roundtrip(x::Int64)::Int64 ---");
    const rt = await loadWasm("roundtrip");
    const rtExports = Object.keys(rt.exports).filter(k => typeof rt.exports[k] === 'function');
    console.log(`  Exports: ${rtExports.join(', ')}`);
    const rtFn = rt.exports[rtExports[0]];
    for (const x of [0n, 1n, 3n, 100n, -1n]) {
        try {
            const result = rtFn(x);
            const correct = result === x;
            console.log(`  roundtrip(${x}) = ${result} → ${correct ? "CORRECT" : "WRONG"}`);
        } catch (e) {
            console.log(`  roundtrip(${x}) = ERROR: ${e.message}`);
        }
    }
    console.log();

    // Test 2: add_trunc
    console.log("--- add_trunc(a::Int64, b::Int64)::Int64 ---");
    const at = await loadWasm("add_trunc");
    const atExports = Object.keys(at.exports).filter(k => typeof at.exports[k] === 'function');
    console.log(`  Exports: ${atExports.join(', ')}`);
    const atFn = at.exports[atExports[0]];
    for (const [a, b, expected] of [[0n, 0n, 0n], [0n, 1n, 1n], [1n, 0n, 1n], [1n, 1n, 2n], [3n, 0n, 3n]]) {
        try {
            const result = atFn(a, b);
            const correct = result === expected;
            console.log(`  add_trunc(${a}, ${b}) = ${result} (expected ${expected}) → ${correct ? "CORRECT" : "WRONG"}`);
        } catch (e) {
            console.log(`  add_trunc(${a}, ${b}) = ERROR: ${e.message}`);
        }
    }
    console.log();

    // Test 3: seek
    console.log("--- seek(offset::Int64, position::Int64)::Int64 ---");
    const sk = await loadWasm("seek");
    const skExports = Object.keys(sk.exports).filter(k => typeof sk.exports[k] === 'function');
    console.log(`  Exports: ${skExports.join(', ')}`);
    const skFn = sk.exports[skExports[0]];
    for (const [off, pos, expected] of [[0n, 0n, 1n], [0n, 1n, 2n], [1n, 0n, 2n]]) {
        try {
            const result = skFn(off, pos);
            const correct = result === expected;
            console.log(`  seek(${off}, ${pos}) = ${result} (expected ${expected}) → ${correct ? "CORRECT" : "WRONG"}`);
            if (!correct) {
                console.log(`    DETAIL: expected ${expected}, got ${result} (diff: ${result - expected})`);
                if (result === -1n) {
                    console.log("    This means the Int128 round-trip check FAILED (inexact truncation)");
                }
            }
        } catch (e) {
            console.log(`  seek(${off}, ${pos}) = ERROR: ${e.message}`);
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
