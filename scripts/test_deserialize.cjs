#!/usr/bin/env node
// ============================================================================
// test_deserialize.cjs — GAMMA-003: JS Deserializer + Roundtrip Test
// ============================================================================
// Tests the full pipeline:
//   1. Load codegen E2E WASM module
//   2. Parse CodeInfo JSON (passed as CLI arg or stdin)
//   3. Deserialize JSON → WASM IR structs (via WASM constructors)
//   4. Compile IR → WASM bytes (via WASM mini-compiler)
//   5. Instantiate compiled bytes → execute f(5n) === 26n
//
// Usage:
//   node scripts/test_deserialize.cjs <codeinfo.json> <codegen.wasm>
//   # Or from Julia test harness which generates JSON inline

'use strict';

const fs = require('fs');
const path = require('path');
const { compileFromJson } = require('./deserialize_codeinfo.cjs');

async function main() {
    const args = process.argv.slice(2);
    if (args.length < 2) {
        console.error('Usage: node test_deserialize.cjs <codeinfo.json> <codegen.wasm>');
        process.exit(1);
    }

    const jsonPath = args[0];
    const wasmPath = args[1];

    let passed = 0;
    let failed = 0;

    function test(name, fn) {
        try {
            const result = fn();
            if (result === true || result === undefined) {
                console.log(`  PASS: ${name}`);
                passed++;
            } else {
                console.log(`  FAIL: ${name} — returned ${result}`);
                failed++;
            }
        } catch (e) {
            console.log(`  FAIL: ${name} — ${e.message}`);
            failed++;
        }
    }

    async function testAsync(name, fn) {
        try {
            const result = await fn();
            if (result === true || result === undefined) {
                console.log(`  PASS: ${name}`);
                passed++;
            } else {
                console.log(`  FAIL: ${name} — returned ${result}`);
                failed++;
            }
        } catch (e) {
            console.log(`  FAIL: ${name} — ${e.message}`);
            failed++;
        }
    }

    // --- Step 1: Load codegen WASM module ---
    console.log('Step 1: Loading codegen WASM module...');
    const codegenBytes = fs.readFileSync(wasmPath);
    const codegenMod = await WebAssembly.compile(codegenBytes);

    // Create stub imports for any missing imports
    const stubs = {};
    for (const imp of WebAssembly.Module.imports(codegenMod)) {
        if (!stubs[imp.module]) stubs[imp.module] = {};
        if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
    }

    const codegenInst = await WebAssembly.instantiate(codegenMod, stubs);
    const e = codegenInst.exports;
    console.log(`  Loaded ${Object.keys(e).length} exports`);

    // --- Step 2: Parse CodeInfo JSON ---
    console.log('Step 2: Parsing CodeInfo JSON...');
    const jsonStr = fs.readFileSync(jsonPath, 'utf8');
    const json = JSON.parse(jsonStr);
    console.log(`  Entries: ${json.entries.length}`);
    console.log(`  Function: ${json.entries[0].name}`);
    console.log(`  Statements: ${json.entries[0].code.length}`);

    // --- Step 3: Test individual constructor calls ---
    console.log('Step 3: Testing constructor calls...');

    test('wasm_symbol_call returns non-null', () => {
        return e.wasm_symbol_call() != null;
    });

    test('wasm_create_any_vector(3) returns non-null', () => {
        return e.wasm_create_any_vector(3) != null;
    });

    test('wasm_set_any_i64 sets without error', () => {
        const v = e.wasm_create_any_vector(1);
        e.wasm_set_any_i64(v, 1, 42n);
        return true;
    });

    test('wasm_create_expr builds expression', () => {
        const sym = e.wasm_symbol_call();
        const args = e.wasm_create_any_vector(1);
        e.wasm_set_any_i64(args, 1, 1n);
        const expr = e.wasm_create_expr(sym, args);
        return expr != null;
    });

    test('wasm_create_return_node builds return', () => {
        const ret = e.wasm_create_return_node(1);
        return ret != null;
    });

    // --- Step 4: Full deserialize + compile ---
    console.log('Step 4: Full deserialize + compile...');

    let compiledBytes = null;

    await testAsync('compileFromJson produces bytes', async () => {
        compiledBytes = compileFromJson(e, json);
        console.log(`    Compiled ${compiledBytes.length} bytes`);
        console.log(`    Magic: ${Array.from(compiledBytes.slice(0, 4)).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ')}`);
        return compiledBytes.length > 0 && compiledBytes[0] === 0x00 && compiledBytes[1] === 0x61;
    });

    // --- Step 5: Validate compiled bytes ---
    console.log('Step 5: Validating compiled WASM...');

    let userMod = null;
    await testAsync('WebAssembly.compile succeeds', async () => {
        userMod = await WebAssembly.compile(compiledBytes);
        const exports = WebAssembly.Module.exports(userMod);
        console.log(`    User module has ${exports.length} export(s): ${exports.map(e => e.name).join(', ')}`);
        return exports.length > 0;
    });

    // --- Step 6: Execute compiled function ---
    console.log('Step 6: Executing compiled function...');

    await testAsync('f(5n) === 26n', async () => {
        const userInst = await WebAssembly.instantiate(userMod);
        const f = userInst.exports.f;
        const result = f(5n);
        console.log(`    f(5) = ${result}`);
        return result === 26n;
    });

    await testAsync('f(0n) === 1n', async () => {
        const userInst = await WebAssembly.instantiate(userMod);
        const result = userInst.exports.f(0n);
        console.log(`    f(0) = ${result}`);
        return result === 1n;
    });

    await testAsync('f(-3n) === 10n', async () => {
        const userInst = await WebAssembly.instantiate(userMod);
        const result = userInst.exports.f(-3n);
        console.log(`    f(-3) = ${result}`);
        return result === 10n;
    });

    // --- Summary ---
    console.log(`\n${'='.repeat(50)}`);
    console.log(`Results: ${passed} passed, ${failed} failed out of ${passed + failed}`);
    console.log(`${'='.repeat(50)}`);
    process.exit(failed > 0 ? 1 : 0);
}

main().catch(err => {
    console.error('Fatal error:', err.message);
    process.exit(1);
});
