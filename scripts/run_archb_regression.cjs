#!/usr/bin/env node
// ============================================================================
// run_archb_regression.cjs — X-001: Architecture B 30-function regression suite
// ============================================================================
// Tests 30 functions via zero-server WASM compilation.
// Each: compile_source in WASM → execute → compare to expected.

'use strict';

const fs = require('fs');
const path = require('path');

async function main() {
    const wasmPath = process.argv[2] || path.join(__dirname, '..', 'archb-compiler.wasm');

    console.log('╔══════════════════════════════════════════════════════╗');
    console.log('║  X-001: Architecture B 30-Function Regression Suite ║');
    console.log('╚══════════════════════════════════════════════════════╝');
    console.log();

    // Load compiler module
    const compilerBytes = fs.readFileSync(wasmPath);
    const compilerMod = await WebAssembly.compile(compilerBytes);
    const stubs = {};
    for (const imp of WebAssembly.Module.imports(compilerMod)) {
        if (!stubs[imp.module]) stubs[imp.module] = {};
        if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
    }
    const compiler = await WebAssembly.instantiate(compilerMod, stubs);
    const e = compiler.exports;
    console.log(`Compiler: ${Object.keys(e).length} exports, ${(compilerBytes.length / 1024).toFixed(1)} KB\n`);

    function toWasmString(jsStr) {
        const len = jsStr.length;
        const ws = e.create_wasm_string(len);
        for (let i = 0; i < len; i++) e.set_string_char(ws, i + 1, jsStr.charCodeAt(i));
        return ws;
    }

    function fromWasmBytes(wasmVec) {
        const len = e.wasm_bytes_length(wasmVec);
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) bytes[i] = e.wasm_bytes_get(wasmVec, i + 1);
        return bytes;
    }

    async function compileAndRun(source, args) {
        const ws = toWasmString(source);
        const wasmBytes = e.wasm_compile_source(ws, source.length);
        const bytes = fromWasmBytes(wasmBytes);
        const userMod = await WebAssembly.compile(bytes);
        const userInst = await WebAssembly.instantiate(userMod, {});
        return userInst.exports.f(...args);
    }

    // 30 test functions covering the playground subset
    const tests = [
        // --- Basic arithmetic (1-5) ---
        ['f(x::Int64)=x+1', [5n], 6n, 'increment'],
        ['f(x::Int64)=x*2', [7n], 14n, 'double'],
        ['f(x::Int64)=x*x', [6n], 36n, 'square'],
        ['f(x::Int64)=x*x+1', [5n], 26n, 'square+1'],
        ['f(x::Int64)=x*x*x', [3n], 27n, 'cube'],

        // --- Two-parameter (6-10) ---
        ['f(x::Int64,y::Int64)=x+y', [3n, 5n], 8n, 'add'],
        ['f(x::Int64,y::Int64)=x-y', [10n, 3n], 7n, 'subtract'],
        ['f(x::Int64,y::Int64)=x*y', [4n, 7n], 28n, 'multiply'],
        ['f(x::Int64,y::Int64)=x/y', [20n, 4n], 5n, 'divide'],
        ['f(x::Int64,y::Int64)=x*y+x-y', [3n, 4n], 11n, 'mixed ops'],

        // --- Parenthesized (11-15) ---
        ['f(x::Int64)=(x+1)*(x-1)', [5n], 24n, 'diff of squares'],
        ['f(x::Int64)=(x+2)*(x+3)', [1n], 12n, 'factors'],
        ['f(x::Int64,y::Int64)=(x+y)*(x-y)', [5n, 3n], 16n, '(a+b)(a-b)'],
        ['f(x::Int64)=(x+x)*(x+x)', [3n], 36n, 'doubled squared'],
        ['f(x::Int64)=((x+1)+1)', [8n], 10n, 'nested parens'],

        // --- Identity and constants (16-20) ---
        ['f(x::Int64)=x', [42n], 42n, 'identity'],
        ['f(x::Int64)=0', [99n], 0n, 'constant zero'],
        ['f(x::Int64)=1', [99n], 1n, 'constant one'],
        ['f(x::Int64)=100', [0n], 100n, 'constant 100'],
        ['f(x::Int64,y::Int64)=y', [1n, 2n], 2n, 'second param'],

        // --- Polynomials (21-25) ---
        ['f(x::Int64)=x*x+x+1', [3n], 13n, 'x^2+x+1'],
        ['f(x::Int64)=x*x*x+x*x+x+1', [2n], 15n, 'x^3+x^2+x+1'],
        ['f(x::Int64)=2*x*x+3*x+4', [5n], 69n, '2x^2+3x+4'],
        ['f(x::Int64,y::Int64)=x*x+2*x*y+y*y', [3n, 2n], 25n, '(x+y)^2 expanded'],
        ['f(x::Int64)=x*x-2*x+1', [5n], 16n, '(x-1)^2 expanded'],

        // --- Three parameters (26-28) ---
        ['f(x::Int64,y::Int64,z::Int64)=x+y+z', [1n, 2n, 3n], 6n, 'sum3'],
        ['f(x::Int64,y::Int64,z::Int64)=x*y+z', [3n, 4n, 5n], 17n, 'mul+add3'],
        ['f(x::Int64,y::Int64,z::Int64)=x*y*z', [2n, 3n, 4n], 24n, 'mul3'],

        // --- Complex expressions (29-30) ---
        ['f(x::Int64)=(x+1)*(x+2)*(x+3)', [1n], 24n, 'triple product'],
        ['f(x::Int64,y::Int64)=x*x*y+x*y*y', [2n, 3n], 30n, 'xy(x+y)'],
    ];

    let passed = 0;
    let failed = 0;

    for (let i = 0; i < tests.length; i++) {
        const [source, args, expected, desc] = tests[i];
        try {
            const result = await compileAndRun(source, args);
            const ok = result === expected;
            if (ok) {
                passed++;
                console.log(`  ${String(i + 1).padStart(2)}. ✅ ${desc.padEnd(25)} ${source}`);
            } else {
                failed++;
                console.log(`  ${String(i + 1).padStart(2)}. ❌ ${desc.padEnd(25)} ${source}  got=${result} expected=${expected}`);
            }
        } catch (err) {
            failed++;
            console.log(`  ${String(i + 1).padStart(2)}. ❌ ${desc.padEnd(25)} ${source}  ERROR: ${err.message}`);
        }
    }

    console.log('\n' + '═'.repeat(56));
    console.log(`RESULT: ${passed}/${tests.length} passed, ${failed} failed`);
    console.log('═'.repeat(56));

    if (passed === tests.length) {
        console.log('\n✅ All 30 regression tests PASS!');
    }
    process.exit(failed > 0 ? 1 : 0);
}

main().catch(err => { console.error('Fatal:', err); process.exit(1); });
