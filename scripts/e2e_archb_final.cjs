#!/usr/bin/env node
// ============================================================================
// e2e_archb_final.cjs — Architecture B: ZERO SERVER Julia-to-WASM Compilation
// ============================================================================
// Full pipeline entirely in WASM:
//   1. JS creates WasmGC string from user source
//   2. WASM wasm_compile_source: parse → lower → codegen → binary assembly
//   3. JS extracts bytes from WasmGC Vector{UInt8}
//   4. JS calls WebAssembly.compile on the bytes
//   5. Execute the resulting user module
//
// ZERO native Julia. ZERO server. ALL compilation in WASM.

'use strict';

const fs = require('fs');
const path = require('path');

async function main() {
    const wasmPath = process.argv[2] || path.join(__dirname, '..', 'archb-compiler.wasm');

    console.log('╔══════════════════════════════════════════════════════╗');
    console.log('║  Architecture B: ZERO-SERVER Julia→WASM Compilation ║');
    console.log('║  ALL parsing + compilation happens in WASM          ║');
    console.log('║  NO native Julia, NO server, NO JS compilation      ║');
    console.log('╚══════════════════════════════════════════════════════╝');
    console.log();

    // --- Load compiler WASM module ---
    console.log('1. Loading compiler WASM module...');
    const compilerBytes = fs.readFileSync(wasmPath);
    const compilerMod = await WebAssembly.compile(compilerBytes);

    // Build stub imports for any required imports
    const stubs = {};
    for (const imp of WebAssembly.Module.imports(compilerMod)) {
        if (!stubs[imp.module]) stubs[imp.module] = {};
        if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
    }
    const compiler = await WebAssembly.instantiate(compilerMod, stubs);
    const e = compiler.exports;
    console.log(`   Compiler: ${Object.keys(e).length} exports, ${(compilerBytes.length / 1024).toFixed(1)} KB`);

    // --- Helper: JS string → WasmGC string ---
    function toWasmString(jsStr) {
        const len = jsStr.length;
        const wasmStr = e.create_wasm_string(len);
        for (let i = 0; i < len; i++) {
            e.set_string_char(wasmStr, i + 1, jsStr.charCodeAt(i));
        }
        return wasmStr;
    }

    // --- Helper: WasmGC Vector{UInt8} → JS Uint8Array ---
    function fromWasmBytes(wasmVec) {
        const len = e.wasm_bytes_length(wasmVec);
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) {
            bytes[i] = e.wasm_bytes_get(wasmVec, i + 1);
        }
        return bytes;
    }

    // --- Compile and execute a Julia source string ---
    async function compileAndRun(source, args, expected) {
        console.log(`\n   Compiling: ${source}`);

        // Step 1: Create WasmGC string from source
        const wasmSource = toWasmString(source);
        const sourceLen = source.length;

        // Step 2: Compile in WASM (parse + lower + codegen + binary assembly)
        const wasmBytes = e.wasm_compile_source(wasmSource, sourceLen);

        // Step 3: Extract bytes
        const bytes = fromWasmBytes(wasmBytes);
        console.log(`   Compiled: ${bytes.length} bytes`);

        // Step 4: WebAssembly.compile the user module
        const userMod = await WebAssembly.compile(bytes);
        const userInst = await WebAssembly.instantiate(userMod, {});

        // Step 5: Execute
        const result = userInst.exports.f(...args);
        const pass = result === expected;
        console.log(`   f(${args.join(', ')}) = ${result} ${pass ? '✅ PASS' : '❌ FAIL (expected ' + expected + ')'}`);
        return pass;
    }

    // --- Test suite ---
    console.log('\n2. Running test suite...');

    let passed = 0;
    let total = 0;

    const tests = [
        // [source, args, expected]
        ['f(x::Int64)=x*x+1', [5n], 26n],
        ['f(x::Int64,y::Int64)=x+y', [3n, 5n], 8n],
        ['f(x::Int64)=x*x', [5n], 25n],
        ['f(x::Int64)=(x+1)*(x-1)', [5n], 24n],
        ['f(x::Int64)=x', [42n], 42n],
        ['f(x::Int64)=x*2+3', [10n], 23n],
        ['f(x::Int64,y::Int64)=x*y+x+y', [3n, 4n], 19n],
        ['f(x::Int64)=(x+x)*(x+x)', [3n], 36n],
        ['f(x::Int64)=x-1', [10n], 9n],
        ['f(x::Int64,y::Int64)=x*x+y*y', [3n, 4n], 25n],
    ];

    for (const [source, args, expected] of tests) {
        total++;
        try {
            if (await compileAndRun(source, args, expected)) passed++;
        } catch (err) {
            console.log(`   ❌ ERROR: ${err.message}`);
        }
    }

    console.log('\n' + '═'.repeat(56));
    console.log(`RESULT: ${passed}/${total} tests passed`);
    console.log('═'.repeat(56));

    if (passed === total) {
        console.log('\n🎉 Architecture B COMPLETE: ZERO server, ALL compilation in WASM!');
        process.exit(0);
    } else {
        process.exit(1);
    }
}

main().catch(err => {
    console.error('Fatal:', err);
    process.exit(1);
});
