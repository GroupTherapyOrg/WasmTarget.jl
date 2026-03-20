#!/usr/bin/env node
// ============================================================================
// e2e_demo_arch_a.cjs — GAMMA-005: Architecture A E2E Demo
// ============================================================================
// Full pipeline:
//   Server:  serialize_ir_entries('f(x::Int64) = x * x + 1') → JSON
//   Browser: load codegen WASM → deserialize JSON → compile → f(5n) === 26n
//
// ZERO native Julia in the codegen path.
//
// Usage:
//   # Generate JSON first:
//   julia +1.12 --project=. -e 'using WasmTarget; f(x::Int64)=x*x+1; ...'
//   # Then run:
//   node scripts/e2e_demo_arch_a.cjs <codeinfo.json> [codegen.wasm]

'use strict';

const fs = require('fs');
const path = require('path');
const { compileFromJson, deserializeEntry } = require('./deserialize_codeinfo.cjs');

async function main() {
    const jsonPath = process.argv[2];
    const wasmPath = process.argv[3] || path.join(__dirname, '..', 'self-hosted-codegen-e2e.wasm');

    if (!jsonPath) {
        console.error('Usage: node e2e_demo_arch_a.cjs <codeinfo.json> [codegen.wasm]');
        process.exit(1);
    }

    console.log('╔══════════════════════════════════════════════════════╗');
    console.log('║  Architecture A E2E Demo                            ║');
    console.log('║  Server CodeInfo → Browser WASM Codegen → Execute   ║');
    console.log('╚══════════════════════════════════════════════════════╝');
    console.log();

    // --- Load codegen WASM module ---
    console.log('1. Loading codegen WASM module...');
    const codegenBytes = fs.readFileSync(wasmPath);
    const codegenMod = await WebAssembly.compile(codegenBytes);

    const stubs = {};
    for (const imp of WebAssembly.Module.imports(codegenMod)) {
        if (!stubs[imp.module]) stubs[imp.module] = {};
        if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
    }

    const codegenInst = await WebAssembly.instantiate(codegenMod, stubs);
    const e = codegenInst.exports;
    console.log(`   Codegen module: ${Object.keys(e).length} exports, ${(codegenBytes.length / 1024).toFixed(1)} KB`);

    // --- Parse server-generated CodeInfo JSON ---
    console.log('2. Parsing server CodeInfo JSON...');
    const jsonStr = fs.readFileSync(jsonPath, 'utf8');
    const json = JSON.parse(jsonStr);
    const entry = json.entries[0];
    console.log(`   Function: ${entry.name}(${(entry.arg_types || []).join(', ')}) → ${entry.return_type}`);
    console.log(`   Statements: ${entry.code.length}`);

    // --- Deserialize via WASM constructors (validates bridge) ---
    console.log('3. Deserializing via WASM constructors...');
    const { code, ssatypes, nargs, verified } = deserializeEntry(e, entry);
    console.log(`   WASM IR: code=${e.wasm_any_vector_length(code)} stmts, nargs=${nargs}, verified=${verified}`);

    // --- Compile to WASM binary ---
    console.log('4. Compiling to WASM binary...');
    const userBytes = compileFromJson(e, json);
    console.log(`   Output: ${userBytes.length} bytes`);

    // --- Instantiate and execute ---
    console.log('5. Instantiating user module...');
    const userMod = await WebAssembly.compile(userBytes);
    const userInst = await WebAssembly.instantiate(userMod);
    const f = userInst.exports.f;

    console.log('6. Executing...');
    const test_cases = [
        { input: 5n, expected: 26n },
        { input: 0n, expected: 1n },
        { input: -3n, expected: 10n },
        { input: 10n, expected: 101n },
        { input: 1n, expected: 2n },
    ];

    let allPass = true;
    for (const { input, expected } of test_cases) {
        const result = f(input);
        const pass = result === expected;
        console.log(`   f(${input}) = ${result} ${pass ? '✓' : '✗ EXPECTED ' + expected}`);
        if (!pass) allPass = false;
    }

    console.log();
    if (allPass) {
        console.log('══════════════════════════════════════════════════════');
        console.log('  ARCHITECTURE A E2E: PASS');
        console.log('  Server CodeInfo → WASM codegen → f(5n) === 26n');
        console.log('  ZERO native Julia in the codegen path.');
        console.log('══════════════════════════════════════════════════════');
        process.exit(0);
    } else {
        console.log('  ARCHITECTURE A E2E: FAIL');
        process.exit(1);
    }
}

main().catch(err => {
    console.error('Fatal:', err.message);
    process.exit(1);
});
