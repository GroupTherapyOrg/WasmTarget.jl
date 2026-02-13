#!/usr/bin/env node
// PURE-325: Node.js batch isolation test for build_tree functions
// Tests compiled .wasm files against native Julia ground truth

import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const isolationDir = join(__dirname, '..', 'browser', 'isolation');
const runtimePath = join(__dirname, '..', 'browser', 'wasmtarget-runtime.js');

// Load the WasmTarget runtime
const runtimeCode = readFileSync(runtimePath, 'utf-8');
const WRT = new Function(runtimeCode + '\nreturn WasmTargetRuntime;')();

const results = [];

async function testWasm(name, wasmFile, funcName, args, expected, description) {
    process.stdout.write(`  ${name}: `);
    try {
        const rt = new WRT();
        const bytes = readFileSync(join(isolationDir, wasmFile));
        const mod = await rt.load(bytes, name);

        // Convert string args to wasm strings
        const wasmArgs = [];
        for (const arg of args) {
            if (typeof arg === 'string') {
                wasmArgs.push(await rt.jsToWasmString(arg));
            } else {
                wasmArgs.push(arg);
            }
        }

        const result = mod.exports[funcName](...wasmArgs);

        // Convert BigInt to Number for comparison
        const numResult = typeof result === 'bigint' ? Number(result) : result;

        if (numResult === expected) {
            console.log(`CORRECT (${numResult} === ${expected})`);
            results.push({ name, status: 'CORRECT', expected, actual: numResult });
        } else {
            console.log(`MISMATCH (got ${numResult}, expected ${expected})`);
            results.push({ name, status: 'MISMATCH', expected, actual: numResult });
        }
    } catch (e) {
        const msg = e.message || String(e);
        // Check if it's a trap/runtime error
        if (msg.includes('unreachable') || msg.includes('null') || msg.includes('out of bounds') || msg.includes('trap')) {
            console.log(`CRASHES: ${msg.substring(0, 80)}`);
            results.push({ name, status: 'CRASHES', error: msg.substring(0, 80) });
        } else {
            console.log(`ERROR: ${msg.substring(0, 80)}`);
            results.push({ name, status: 'ERROR', error: msg.substring(0, 80) });
        }
    }
}

console.log('='.repeat(60));
console.log('PURE-325: Node.js Batch Isolation Test — build_tree functions');
console.log('='.repeat(60));

// ============================================================================
// Test wrapper functions (return simple numeric types)
// ============================================================================

console.log('\n--- Wrapper Functions (i64 return) ---');

// Native Julia ground truth:
// tryparse_internal(Int64, "1", 1, 1, 10, false) = 1
// tryparse_internal(Int64, "42", 1, 2, 10, false) = 42
// tryparse_internal(Int64, "999", 1, 3, 10, false) = 999
await testWasm('tryparse_int64("1")', 'wrap_tryparse_int64.wasm', 'wrap_tryparse_int64', ['1'], 1, 'Int64 parse of "1"');
await testWasm('tryparse_int64("42")', 'wrap_tryparse_int64.wasm', 'wrap_tryparse_int64', ['42'], 42, 'Int64 parse of "42"');
await testWasm('tryparse_int64("999")', 'wrap_tryparse_int64.wasm', 'wrap_tryparse_int64', ['999'], 999, 'Int64 parse of "999"');
await testWasm('tryparse_int64("abc")', 'wrap_tryparse_int64.wasm', 'wrap_tryparse_int64', ['abc'], -1, 'Non-numeric returns -1');

// parse_int_literal wraps tryparse for Int64/Int128/BigInt
// Native: parse_int_literal("1") = 1, parse_int_literal("42") = 42, parse_int_literal("1_000") = 1000
await testWasm('parse_int_literal("1")', 'wrap_parse_int_literal.wasm', 'wrap_parse_int_literal', ['1'], 1, 'Integer literal "1"');
await testWasm('parse_int_literal("42")', 'wrap_parse_int_literal.wasm', 'wrap_parse_int_literal', ['42'], 42, 'Integer literal "42"');
await testWasm('parse_int_literal("1_000")', 'wrap_parse_int_literal.wasm', 'wrap_parse_int_literal', ['1_000'], 1000, 'Integer literal "1_000" (underscore)');

// take!(IOBuffer) — returns length
// Native: 5 ("hello" = 5 bytes)
console.log('\n--- IOBuffer ---');
await testWasm('take_length', 'wrap_take_length.wasm', 'wrap_take_length', [], 5, 'IOBuffer take! returns 5 bytes');

// parse_float_literal
// Native: parse_float_literal(Float64, "1.0") = 1.0, parse_float_literal(Float64, "3.14") = 3.1 (3 char input)
console.log('\n--- Float Parsing ---');
await testWasm('parse_float("1.0")', 'wrap_parse_float.wasm', 'wrap_parse_float', ['1.0'], 1.0, 'Float literal "1.0"');
await testWasm('parse_float("3.14")', 'wrap_parse_float.wasm', 'wrap_parse_float', ['3.14'], 3.14, 'Float literal "3.14"');

// ============================================================================
// Summary
// ============================================================================

console.log('\n' + '='.repeat(60));
console.log('SUMMARY');
console.log('='.repeat(60));
console.log();
console.log('| Test | Status | Expected | Actual |');
console.log('|------|--------|----------|--------|');
for (const r of results) {
    if (r.status === 'CORRECT') {
        console.log(`| ${r.name} | CORRECT | ${r.expected} | ${r.actual} |`);
    } else if (r.status === 'MISMATCH') {
        console.log(`| ${r.name} | MISMATCH | ${r.expected} | ${r.actual} |`);
    } else {
        console.log(`| ${r.name} | ${r.status} | — | ${r.error || ''} |`);
    }
}

const correct = results.filter(r => r.status === 'CORRECT').length;
const total = results.length;
console.log(`\nResults: ${correct}/${total} CORRECT`);

if (correct === total) {
    console.log('ALL TESTS PASS!');
} else {
    const failures = results.filter(r => r.status !== 'CORRECT');
    console.log(`\nFailing tests:`);
    for (const f of failures) {
        console.log(`  - ${f.name}: ${f.status} ${f.error || `(got ${f.actual}, expected ${f.expected})`}`);
    }
}
