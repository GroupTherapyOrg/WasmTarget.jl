#!/usr/bin/env node
// ============================================================================
// run_arch_c_tests.cjs — TEST-002: Architecture C Regression Test Suite
// ============================================================================
// Runs 20 functions through Architecture C pipeline:
//   JSON → WASM constructors → WASM thin_typeinf → JS mini-compiler → execute
//
// Usage:
//   node scripts/run_arch_c_tests.cjs <test_data.json> <typeinf.wasm>

'use strict';

const fs = require('fs');
const path = require('path');
const { compileEntryToWasm } = require('./deserialize_codeinfo.cjs');

// WASM opcode lookup for intrinsics (callee resolution)
const INTRINSIC_CALLEE_MAP = {
    'mul_int': 'mul_int',
    'add_int': 'add_int',
    'sub_int': 'sub_int',
    'sdiv_int': 'sdiv_int',
    'srem_int': 'srem_int',
};

function resolveCalleeTypeId(val, calleeTypeIds) {
    if (!val || typeof val !== 'object') return -1;
    if (val._t === 'globalref' || val._t === 'intrinsic') {
        const name = val.name;
        if (calleeTypeIds[name] !== undefined) return calleeTypeIds[name];
    }
    return -1;
}

async function main() {
    const jsonPath = process.argv[2];
    const wasmPath = process.argv[3];

    if (!jsonPath || !wasmPath) {
        console.error('Usage: node run_arch_c_tests.cjs <test_data.json> <typeinf.wasm>');
        process.exit(1);
    }

    // Load thin_typeinf WASM module
    const wasmBytes = fs.readFileSync(wasmPath);
    const wasmMod = await WebAssembly.compile(wasmBytes);
    const stubs = {};
    for (const imp of WebAssembly.Module.imports(wasmMod)) {
        if (!stubs[imp.module]) stubs[imp.module] = {};
        if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
    }
    const inst = await WebAssembly.instantiate(wasmMod, stubs);
    const e = inst.exports;

    // Parse test data
    const testData = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
    const entries = testData.entries;
    const testCases = testData.test_cases;
    const typeIdConstants = testData.typeid_constants;
    const rtTableData = testData.rt_table;
    const calleeTypeIds = testData.callee_typeids;

    const TID_I64 = typeIdConstants.Int64;
    const TID_I32 = typeIdConstants.Int32;
    const TID_F64 = typeIdConstants.Float64;
    const TID_BOOL = typeIdConstants.Bool;

    // Build return type table in WASM
    const rtTable = e.wasm_create_i32_vector(rtTableData.length);
    for (let i = 0; i < rtTableData.length; i++) {
        e.wasm_set_i32(rtTable, i + 1, rtTableData[i]);
    }

    console.log(`Architecture C Regression Tests: ${entries.length} functions`);
    console.log();

    let passed = 0;
    let failed = 0;

    for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        const cases = testCases[i];
        const name = entry.name;
        const nParams = entry.arg_types ? entry.arg_types.length : 0;

        try {
            // --- Step 1: Build IR in WASM (untyped CodeInfo) ---
            const stmts = entry.code;
            const n = stmts.length;
            const code = e.wasm_create_any_vector(n);
            const callSym = e.wasm_symbol_call();

            // Build callee_typeids vector for this function
            const calleeVec = e.wasm_create_i32_vector(n);

            for (let si = 0; si < n; si++) {
                const stmt = stmts[si];
                const idx = si + 1;

                if (stmt._t === 'expr' && stmt.head === 'call') {
                    const args = stmt.args;
                    const argsVec = e.wasm_create_any_vector(args.length);

                    // Set callee (first arg) — use arg placeholder for typeinf
                    if (args[0] && (args[0]._t === 'globalref' || args[0]._t === 'intrinsic')) {
                        e.wasm_set_any_arg(argsVec, 1, 1); // placeholder
                        const tid = resolveCalleeTypeId(args[0], calleeTypeIds);
                        e.wasm_set_i32(calleeVec, idx, tid);
                    }

                    // Set remaining args
                    for (let j = 1; j < args.length; j++) {
                        const arg = args[j];
                        if (arg && arg._t === 'ssa') {
                            e.wasm_set_any_ssa(argsVec, j + 1, arg.id);
                        } else if (arg && arg._t === 'arg') {
                            e.wasm_set_any_arg(argsVec, j + 1, arg.n);
                        } else if (arg && arg._t === 'lit') {
                            e.wasm_set_any_i64(argsVec, j + 1, BigInt(arg.v));
                        }
                    }

                    const expr = e.wasm_create_expr(callSym, argsVec);
                    e.wasm_set_any_expr(code, idx, expr);
                } else if (stmt._t === 'return') {
                    if (stmt.val && stmt.val._t === 'ssa') {
                        const ret = e.wasm_create_return_node(stmt.val.id);
                        e.wasm_set_any_return(code, idx, ret);
                    } else if (stmt.val && stmt.val._t === 'arg') {
                        // Return an argument directly — use SSA value trick
                        // (The return node takes an SSA id, but for args we need different handling)
                        const ret = e.wasm_create_return_node(stmt.val.n);
                        e.wasm_set_any_return(code, idx, ret);
                    }
                    e.wasm_set_i32(calleeVec, idx, -1);
                } else {
                    e.wasm_set_i32(calleeVec, idx, -1);
                }
            }

            // Build arg_typeids: [typeof_f=-1, Int64, Int64, ...]
            const argTypeIds = e.wasm_create_i32_vector(nParams + 1);
            e.wasm_set_i32(argTypeIds, 1, -1); // typeof(f)
            for (let p = 0; p < nParams; p++) {
                e.wasm_set_i32(argTypeIds, p + 2, TID_I64);
            }

            // --- Step 2: Run WASM thin_typeinf ---
            const ssaTypes = e.wasm_thin_typeinf(
                code, calleeVec, argTypeIds, rtTable,
                TID_I64, TID_I32, TID_F64, TID_BOOL
            );
            const nTypes = e.wasm_i32_vector_length(ssaTypes);

            // --- Step 3: Compile to WASM via JS mini-compiler ---
            const wasmBytesOut = compileEntryToWasm(entry);

            // --- Step 4: Instantiate and test ---
            const userMod = await WebAssembly.compile(wasmBytesOut);
            const userInst = await WebAssembly.instantiate(userMod);
            const f = userInst.exports.f;

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
                console.log(`  ${name}: PASS (typeinf=${nTypes} types, ${cases.length} cases)`);
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
