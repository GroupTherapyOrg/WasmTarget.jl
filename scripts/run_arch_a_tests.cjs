#!/usr/bin/env node
// ============================================================================
// run_arch_a_tests.cjs — TEST-001: Architecture A Regression Test Suite
// ============================================================================
// Runs 20 functions through Architecture A pipeline:
//   JSON → deserialize via WASM constructors → JS mini-compiler → execute → compare
//
// Usage:
//   node scripts/run_arch_a_tests.cjs <test_data.json> [codegen.wasm]

'use strict';

const fs = require('fs');
const path = require('path');
const { compileEntryToWasm, deserializeEntry } = require('./deserialize_codeinfo.cjs');

async function main() {
    const jsonPath = process.argv[2];
    const wasmPath = process.argv[3] || path.join(__dirname, '..', 'self-hosted-codegen-e2e.wasm');

    if (!jsonPath) {
        console.error('Usage: node run_arch_a_tests.cjs <test_data.json> [codegen.wasm]');
        process.exit(1);
    }

    // Load codegen WASM module (for WASM constructor validation)
    let codegenExports = null;
    if (fs.existsSync(wasmPath)) {
        const codegenBytes = fs.readFileSync(wasmPath);
        const codegenMod = await WebAssembly.compile(codegenBytes);
        const stubs = {};
        for (const imp of WebAssembly.Module.imports(codegenMod)) {
            if (!stubs[imp.module]) stubs[imp.module] = {};
            if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
        }
        const codegenInst = await WebAssembly.instantiate(codegenMod, stubs);
        codegenExports = codegenInst.exports;
    }

    // Parse test data
    const testData = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
    const entries = testData.entries;
    const testCases = testData.test_cases;

    console.log(`Architecture A Regression Tests: ${entries.length} functions`);
    console.log();

    let passed = 0;
    let failed = 0;

    for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        const cases = testCases[i];
        const name = entry.name;

        try {
            // Stage 1: Validate deserialization via WASM constructors (if module available)
            if (codegenExports) {
                const { verified } = deserializeEntry(codegenExports, entry);
                if (!verified) {
                    console.log(`  ${name}: FAIL (WASM deserialization verification failed)`);
                    failed++;
                    continue;
                }
            }

            // Stage 2: Compile to WASM via JS mini-compiler
            const wasmBytes = compileEntryToWasm(entry);

            // Stage 3: Instantiate
            const mod = await WebAssembly.compile(wasmBytes);
            const inst = await WebAssembly.instantiate(mod);
            const f = inst.exports.f;

            // Stage 4: Run test cases
            let allCasesPassed = true;
            for (const tc of cases) {
                const args = tc.inputs.map(v => BigInt(v));
                const expected = BigInt(tc.expected);
                const result = f(...args);
                if (result !== expected) {
                    console.log(`  ${name}: FAIL — ${name}(${tc.inputs.join(', ')}) = ${result}, expected ${expected}`);
                    allCasesPassed = false;
                    break;
                }
            }

            if (allCasesPassed) {
                console.log(`  ${name}: PASS (${cases.length} cases)`);
                passed++;
            } else {
                failed++;
            }
        } catch (err) {
            console.log(`  ${name}: FAIL — ${err.message}`);
            failed++;
        }
    }

    console.log();
    console.log(`Results: ${passed}/${entries.length} passed, ${failed} failed`);
    console.log(passed === entries.length ? 'ALL PASS' : 'SOME FAILED');
    process.exit(failed > 0 ? 1 : 0);
}

main().catch(err => {
    console.error('Fatal:', err.message);
    process.exit(1);
});
