#!/usr/bin/env node
// ============================================================================
// e2e_demo_arch_b.cjs — Architecture B E2E Demo
// ============================================================================
// Full pipeline — ZERO server dependency:
//   Browser: source string → eval_julia WASM → compile → execute
//
// The eval_julia.wasm module contains the FULL Julia compilation pipeline:
//   1. Pattern recognition (byte-level parse)
//   2. Type inference (pre-resolved CodeInfo)
//   3. Codegen (compile_from_codeinfo runs IN WASM)
//   4. WASM binary emission
//
// ZERO native Julia. ZERO server. ALL compilation in WASM.
//
// Usage:
//   node scripts/e2e_demo_arch_b.cjs [eval_julia.wasm]

'use strict';

const fs = require('fs');
const path = require('path');
const { WasmTargetRuntime } = require(path.join(__dirname, '..', 'browser', 'wasmtarget-runtime.js'));

async function main() {
    const wasmPath = process.argv[2] || path.join(__dirname, '..', 'browser', 'eval_julia.wasm');

    console.log('Architecture B E2E Demo');
    console.log('ZERO server. Source string -> browser WASM compile -> execute');
    console.log();

    // --- Load eval_julia WASM module ---
    console.log('1. Loading eval_julia WASM module...');
    const rt = new WasmTargetRuntime();
    const wasmBytes = fs.readFileSync(wasmPath);
    const evalInst = await rt.load(wasmBytes.buffer, 'eval_julia');
    const e = evalInst.exports;
    const funcCount = Object.keys(e).filter(k => typeof e[k] === 'function').length;
    console.log(`   Module: ${funcCount} exports, ${(wasmBytes.length / 1024).toFixed(1)} KB`);

    // --- Test binary integer arithmetic (ZERO server) ---
    console.log('2. Compiling + executing binary integer arithmetic...');

    const test_cases = [
        // [expression, expected_bigint]
        ['1+1', 2n],
        ['2+3', 5n],
        ['10-3', 7n],
        ['6*7', 42n],
        ['5+0', 5n],
        ['100-1', 99n],
        ['3*3', 9n],
        ['7+8', 15n],
        ['9-4', 5n],
        ['4*5', 20n],
    ];

    let allPass = true;
    let passCount = 0;

    for (const [expr, expected] of test_cases) {
        try {
            const result = await rt.evalJulia(evalInst, expr);
            const pass = result === expected;
            console.log(`   evalJulia("${expr}") = ${result} ${pass ? 'PASS' : 'FAIL (expected ' + expected + ')'}`);
            if (pass) passCount++;
            else allPass = false;
        } catch (err) {
            console.log(`   evalJulia("${expr}") ERROR: ${err.message}`);
            allPass = false;
        }
    }

    console.log();
    console.log(`   Results: ${passCount}/${test_cases.length} passed`);

    // --- Direct pipeline demo: compile + instantiate + execute ---
    console.log();
    console.log('3. Direct pipeline demo (no evalJulia wrapper)...');
    console.log('   Source: "1*1" → eval_julia_wasm → WASM bytes → instantiate → execute');

    const wasmStr = await rt.jsToWasmString('1*1');
    const vecRef = e.eval_julia_wasm(wasmStr);
    const len = e.eval_julia_result_length(vecRef);
    const innerBytes = new Uint8Array(len);
    for (let i = 1; i <= len; i++) innerBytes[i - 1] = e.eval_julia_result_byte(vecRef, i);

    console.log(`   eval_julia_wasm produced ${len} bytes`);
    console.log(`   WASM magic: ${innerBytes[0] === 0 && innerBytes[1] === 0x61 ? 'valid' : 'INVALID'}`);

    const innerInst = await rt.load(innerBytes.buffer);
    const mulFn = innerInst.exports['*'];
    const directTests = [[5n, 5n, 25n], [6n, 7n, 42n], [0n, 100n, 0n], [-3n, 4n, -12n]];
    let directPass = true;
    for (const [a, b, expected] of directTests) {
        const result = mulFn(a, b);
        const ok = result === expected;
        console.log(`   ${a} * ${b} = ${result} ${ok ? 'PASS' : 'FAIL'}`);
        if (!ok) directPass = false;
    }
    allPass = allPass && directPass;

    console.log();

    if (allPass) {
        console.log('======================================================');
        console.log('  ARCHITECTURE B E2E: PASS');
        console.log('  Source string -> WASM compile -> execute');
        console.log('  ZERO server. ALL compilation in browser WASM.');
        console.log('  Pipeline: parse -> typeinf -> codegen -> execute');
        console.log('======================================================');
        process.exit(0);
    } else {
        console.log('  ARCHITECTURE B E2E: FAIL');
        process.exit(1);
    }
}

main().catch(err => {
    console.error('Fatal:', err.message);
    process.exit(1);
});
