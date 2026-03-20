#!/usr/bin/env node
// ============================================================================
// e2e_arch_a_demo.cjs — ARCHB G-005: Architecture A E2E Demo
// ============================================================================
// Full pipeline:
//   Server:  serialize_ir_entries('f(x::Int64) = x * x + 1') → JSON
//   Browser: load codegen WASM → deserialize JSON → WASM wasm_compile_flat
//            → extract bytes → WebAssembly.compile → f(5n) === 26n
//
// ZERO native Julia in the codegen path.
// ZERO JS compilation or binary assembly — ALL compilation in WASM.
//
// Usage:
//   julia +1.12 --project=. -e '...' > /tmp/f_codeinfo.json
//   node scripts/e2e_arch_a_demo.cjs /tmp/f_codeinfo.json [codegen.wasm]

'use strict';

const fs = require('fs');
const path = require('path');

// Intrinsic name → WASM i64 opcode mapping (used to build flat instruction buffer)
const INTRINSIC_OPCODES = {
    'mul_int':  0x7e,  // i64.mul
    'add_int':  0x7c,  // i64.add
    'sub_int':  0x7d,  // i64.sub
    'sdiv_int': 0x7f,  // i64.div_s
    'srem_int': 0x81,  // i64.rem_s
    'slt_int':  0x53,  // i64.lt_s
    'sle_int':  0x57,  // i64.le_s
    'eq_int':   0x51,  // i64.eq
    'ne_int':   0x52,  // i64.ne
    'sgt_int':  0x55,  // i64.gt_s
    'sge_int':  0x59,  // i64.ge_s
    'and_int':  0x83,  // i64.and
    'or_int':   0x84,  // i64.or
    'xor_int':  0x85,  // i64.xor
};

/**
 * Convert CodeInfo JSON entry to flat Int32 instruction buffer.
 * This is a TRANSLATION step (JSON → Int32 array), NOT compilation.
 * The WASM module does ALL compilation.
 *
 * JSON uses _t for type tags: "expr", "arg", "ssa", "lit", "globalref", "return"
 */
function entryToFlatInstrs(entry) {
    const instrs = [];

    for (const stmt of entry.code) {
        if (stmt._t === 'expr' && stmt.head === 'call') {
            // Resolve callee to WASM opcode
            const callee = stmt.args[0];
            let opcode = null;
            if (callee._t === 'globalref' && callee.name) {
                opcode = INTRINSIC_OPCODES[callee.name];
            }
            if (opcode == null) continue;  // Skip unsupported callees

            const operands = stmt.args.slice(1);
            instrs.push(0);       // stmt_type = call
            instrs.push(opcode);  // WASM opcode
            instrs.push(operands.length);  // n_operands

            for (const arg of operands) {
                if (arg._t === 'arg') {
                    instrs.push(0);            // kind = param
                    instrs.push(arg.n - 2);    // Argument(2) = param 0
                } else if (arg._t === 'ssa') {
                    instrs.push(1);            // kind = ssa
                    instrs.push(arg.id - 1);   // 0-based SSA index
                } else if (arg._t === 'lit') {
                    instrs.push(2);            // kind = i64 const
                    instrs.push(Number(arg.v));
                }
            }
        } else if (stmt._t === 'return' && stmt.val) {
            instrs.push(1);  // stmt_type = return
            if (stmt.val._t === 'arg') {
                instrs.push(0);                // kind = param
                instrs.push(stmt.val.n - 2);
            } else if (stmt.val._t === 'ssa') {
                instrs.push(1);                // kind = ssa
                instrs.push(stmt.val.id - 1);
            }
        }
    }
    return instrs;
}

async function main() {
    const jsonPath = process.argv[2];
    const wasmPath = process.argv[3] || path.join(__dirname, '..', 'self-hosted-codegen-e2e.wasm');

    if (!jsonPath) {
        console.error('Usage: node e2e_arch_a_demo.cjs <codeinfo.json> [codegen.wasm]');
        process.exit(1);
    }

    console.log('╔══════════════════════════════════════════════════════╗');
    console.log('║  Architecture A E2E Demo (G-005)                    ║');
    console.log('║  Server CodeInfo → WASM Codegen → Execute           ║');
    console.log('║  ZERO JS compilation — ALL in WASM                  ║');
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

    // --- Parse CodeInfo JSON ---
    console.log('2. Parsing server CodeInfo JSON...');
    const jsonStr = fs.readFileSync(jsonPath, 'utf8');
    const json = JSON.parse(jsonStr);
    const entry = json.entries[0];
    const nParams = entry.arg_types ? entry.arg_types.length : 0;
    console.log(`   Function: ${entry.name}(${(entry.arg_types || []).join(', ')}) → ${entry.return_type}`);
    console.log(`   Statements: ${entry.code.length}`);

    // --- Convert JSON to flat Int32 instruction buffer ---
    console.log('3. Building flat instruction buffer...');
    const flatData = entryToFlatInstrs(entry);
    console.log(`   Flat buffer: ${flatData.length} Int32 values`);

    // Build WasmGC Int32 vector from JS array
    const instrs = e.wasm_create_i32_vector(flatData.length);
    for (let i = 0; i < flatData.length; i++) {
        e.wasm_set_i32(instrs, i + 1, flatData[i]);
    }

    // --- Compile IN WASM via wasm_compile_flat ---
    console.log('4. Compiling in WASM (wasm_compile_flat)...');
    const wasmResult = e.wasm_compile_flat(instrs, nParams);
    const len = e.wasm_bytes_length(wasmResult);
    console.log(`   Output: ${len} bytes (compiled entirely in WASM)`);

    // --- Extract bytes from WasmGC Vector{UInt8} ---
    const userBytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
        userBytes[i] = e.wasm_bytes_get(wasmResult, i + 1);
    }

    // --- Instantiate and execute ---
    console.log('5. Instantiating user module...');
    const userMod = await WebAssembly.compile(userBytes);
    const userInst = await WebAssembly.instantiate(userMod);
    const f = userInst.exports.f;

    console.log('6. Executing...');
    const tests = [
        { input: 5n, expected: 26n },
        { input: 0n, expected: 1n },
        { input: -3n, expected: 10n },
        { input: 10n, expected: 101n },
        { input: 1n, expected: 2n },
    ];

    let allPass = true;
    for (const { input, expected } of tests) {
        const result = f(input);
        const ok = result === expected;
        if (!ok) allPass = false;
        console.log(`   f(${input}) = ${result} ${ok ? '✓' : '✗ expected ' + expected}`);
    }

    console.log();
    if (allPass) {
        console.log('══════════════════════════════════════════════════════');
        console.log('  ARCHITECTURE A E2E: PASS');
        console.log('  Server CodeInfo → WASM wasm_compile_flat → f(5n) === 26n');
        console.log('  ZERO native Julia in codegen. ZERO JS compilation.');
        console.log('  ALL binary assembly done by wasm_compile_flat IN WASM.');
        console.log('══════════════════════════════════════════════════════');
    } else {
        console.log('  ARCHITECTURE A E2E: FAIL');
        process.exit(1);
    }
}

main().catch(e => { console.error('ERROR:', e); process.exit(1); });
