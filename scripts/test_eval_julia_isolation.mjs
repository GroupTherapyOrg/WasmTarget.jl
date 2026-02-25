// PURE-7001: Isolation test for cleaned eval_julia module
// Tests individual exported functions to identify first runtime trap.
// Ground truth: native Julia results documented in progress.md
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-7001: Isolation Test — eval_julia.wasm ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    console.log(`File size: ${wasmBytes.length} bytes`);

    const imports = { Math: { pow: Math.pow } };

    let instance;
    try {
        const result = await WebAssembly.instantiate(wasmBytes, imports);
        instance = result.instance;
        console.log("Instantiation: OK\n");
    } catch (e) {
        console.log(`Instantiation FAILED: ${e.message}\n`);
        process.exit(1);
    }

    const ex = instance.exports;

    // List function exports
    const funcExports = Object.keys(ex).filter(k => typeof ex[k] === 'function');
    console.log(`Function exports: ${funcExports.length}`);
    console.log();

    // Helper: create WasmGC byte vec from JS string
    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    let totalTests = 0;
    let passed = 0;

    function test(name, fn) {
        totalTests++;
        try {
            const result = fn();
            console.log(`  PASS: ${name} = ${result}`);
            passed++;
            return result;
        } catch (e) {
            console.log(`  TRAP: ${name} — ${e.message}`);
            return null;
        }
    }

    // === TEST 1: make_byte_vec (most basic — allocate WasmGC array) ===
    console.log("--- Test 1: make_byte_vec ---");
    test("make_byte_vec(3)", () => {
        const v = ex['make_byte_vec'](3);
        return v !== null ? "allocated" : "null";
    });

    // === TEST 2: set_byte_vec! (write bytes into vector) ===
    console.log("\n--- Test 2: set_byte_vec! ---");
    test("set_byte_vec!(vec, 1, 49)", () => {
        const v = ex['make_byte_vec'](3);
        const r = ex['set_byte_vec!'](v, 1, 49); // '1' = 49
        return r; // Expected: 0
    });

    // === TEST 3: jsToWasmBytes helper (combined make + set) ===
    console.log("\n--- Test 3: jsToWasmBytes helper ---");
    test("jsToWasmBytes('1+1')", () => {
        const v = jsToWasmBytes("1+1");
        return v !== null ? "created" : "null";
    });

    // === TEST 4: eval_julia_to_bytes_vec — THE MAIN PIPELINE ===
    // Native Julia ground truth: eval_julia_to_bytes_vec(Vector{UInt8}("1+1")) returns
    // a Vector{UInt8} of valid .wasm bytes. eval_julia_native("1+1") = 2.
    console.log("\n--- Test 4: eval_julia_to_bytes_vec('1+1') ---");
    test("eval_julia_to_bytes_vec('1+1')", () => {
        const v = jsToWasmBytes("1+1");
        const result = ex['eval_julia_to_bytes_vec'](v);
        return result !== null ? "returned bytes" : "null";
    });

    // === TEST 5: If pipeline returned bytes, check length and try to instantiate ===
    console.log("\n--- Test 5: Pipeline result analysis ---");
    try {
        const v = jsToWasmBytes("1+1");
        const wasmResult = ex['eval_julia_to_bytes_vec'](v);
        if (wasmResult !== null) {
            const len = ex['eval_julia_result_length'](wasmResult);
            console.log(`  Result length: ${len} bytes`);

            // Extract bytes
            const resultBytes = new Uint8Array(Number(len));
            for (let i = 0; i < Number(len); i++) {
                resultBytes[i] = Number(ex['eval_julia_result_byte'](wasmResult, i + 1));
            }
            console.log(`  First 4 bytes: [${resultBytes[0]}, ${resultBytes[1]}, ${resultBytes[2]}, ${resultBytes[3]}]`);

            // Check if it's a valid WASM module (starts with 0x00 0x61 0x73 0x6D)
            if (resultBytes[0] === 0x00 && resultBytes[1] === 0x61 &&
                resultBytes[2] === 0x73 && resultBytes[3] === 0x6D) {
                console.log("  Valid WASM magic number!");

                // Try to instantiate the inner module
                try {
                    const innerImports = { Math: { pow: Math.pow } };
                    const inner = await WebAssembly.instantiate(resultBytes, innerImports);
                    const innerEx = inner.instance.exports;
                    const innerFuncs = Object.keys(innerEx).filter(k => typeof innerEx[k] === 'function');
                    console.log(`  Inner module: ${innerFuncs.length} function exports: ${innerFuncs.join(', ')}`);

                    // Try to call the + function
                    if (innerEx['+']) {
                        const result = innerEx['+'](1n, 1n);  // BigInt for i64
                        console.log(`  +(1, 1) = ${result} — ${Number(result) === 2 ? 'CORRECT' : 'WRONG'}`);
                    }
                } catch (e) {
                    console.log(`  Inner module instantiation failed: ${e.message}`);
                }
            } else {
                console.log(`  NOT a valid WASM module (bad magic number)`);
            }
        }
    } catch (e) {
        console.log(`  Pipeline TRAP: ${e.message}`);
    }

    // === TEST 6: Additional arithmetic expressions ===
    console.log("\n--- Test 6: Additional expressions ---");
    for (const [expr, expected] of [["2+3", 5], ["10-3", 7], ["6*7", 42]]) {
        test(`eval_julia('${expr}')`, () => {
            const v = jsToWasmBytes(expr);
            const result = ex['eval_julia_to_bytes_vec'](v);
            return result !== null ? "returned bytes" : "null";
        });
    }

    console.log(`\n=== RESULT: ${passed}/${totalTests} tests passed ===`);
}

main().catch(e => { console.error(e); process.exit(1); });
