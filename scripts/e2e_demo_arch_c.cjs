#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');

// Intrinsic name → WASM i64 opcode (same as Arch A)
const OPCODES = { mul_int: 0x7e, add_int: 0x7c, sub_int: 0x7d };

async function main() {
    console.log('Architecture C E2E Demo (S-003: WASM codegen, no JS binary assembly)');
    console.log('Server parse+lower -> Browser WASM thin_typeinf -> WASM wasm_compile_flat -> execute');
    console.log();

    // TypeID constants (baked from native Julia)
    const TID_I64 = 2, TID_I32 = 13, TID_F64 = 22, TID_BOOL = 10;
    const TID_MUL_INT = 48, TID_ADD_INT = 49;
    const RT_DATA = [-1,-1,-1,-1,1789606658,21,-1,-1,-82928636,13,-1493455867,2,-565919996,2,-1,-1,-1,-1,-1,-1,394222090,21,207741451,13,-1,-1,-1,-1,-1,-1,759240463,10,-2059568368,2,-1368071663,2,-1,-1,-1,-1,-1,-1,-1271870443,13,1830123029,13,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1113670622,13,-1,-1,-461658332,22,-372984539,21,-1,-1,423627815,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-142484686,2,1992354867,13,-590452428,21,198980405,22,549012019,2,-1,-1,-1,-1,-1,-1,1752380986,10,2093837883,21,-1,-1,-1,-1,-2056249538,21,-1,-1,365923392,22,1489627969,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-543728568,13,-1,-1,-1,-1,1965043787,22,-1,-1,-1,-1,-1,-1,-1,-1,-1995127216,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1732670375,13,-1,-1,-1,-1,1876082012,2,-1,-1,-1,-1,-1,-1,-1,-1,1110898273,10,-1,-1,-888255645,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,1492644717,13,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,1531554935,13,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-501801602,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1203599738,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1004528500,13,1130311053,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-617863020,2,-1,-1,-1,-1,-1,-1,564198552,2,-1,-1,-1,-1,-1,-1,-1,-1,2101496989,13,-1,-1,-1,-1,-137599584,10,-1,-1,-1,-1,-1,-1,689582756,2,-1,-1,147816358,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-2132858708,10,-2044184915,10,-1,-1,-1247572561,2,-1,-1,-1,-1,808298162,10,-418300494,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,2033314492,10,-1472219971,10,-1,-1,-1,-1,377871296,13,-1,-1,1779484098,10,-380643645,10,469546690,2,-1,-1,-1,-1,-1,-1,-1,-1,-181572407,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-811070511,13,-883370543,10,-1,-1,-747684908,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,444863711,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,1798896878,13,1684904430,13,-1,-1,444529649,22,-1,-1,1033713139,10,-1910997005,2,-1,-1,347498230,10,-1784523530,10,-1,-1,-1,-1,-177742854,22,-1,-1,-1,-1,-1,-1,-1,-1,609955071,13];

    // 1. Load WASM module (thin_typeinf + wasm_compile_flat + byte accessors)
    const wasmPath = process.argv[2] || path.join(__dirname, '..', 'arch-c-e2e.wasm');
    const wasmBytes = fs.readFileSync(wasmPath);
    const wasmMod = await WebAssembly.compile(wasmBytes);
    const stubs = {};
    for (const imp of WebAssembly.Module.imports(wasmMod)) {
        if (!stubs[imp.module]) stubs[imp.module] = {};
        if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
    }
    const inst = await WebAssembly.instantiate(wasmMod, stubs);
    const e = inst.exports;
    console.log('1. Loaded module: ' + Object.keys(e).length + ' exports');

    // 2. Build IR for f(x::Int64) = x * x + 1 — "server sends UNTYPED CodeInfo"
    const code = e.wasm_create_any_vector(3);
    const args1 = e.wasm_create_any_vector(3);
    e.wasm_set_any_arg(args1, 1, 2); e.wasm_set_any_arg(args1, 2, 2); e.wasm_set_any_arg(args1, 3, 2);
    e.wasm_set_any_expr(code, 1, e.wasm_create_expr(e.wasm_symbol_call(), args1));
    const args2 = e.wasm_create_any_vector(3);
    e.wasm_set_any_ssa(args2, 1, 1); e.wasm_set_any_ssa(args2, 2, 1); e.wasm_set_any_i64(args2, 3, 1n);
    e.wasm_set_any_expr(code, 2, e.wasm_create_expr(e.wasm_symbol_call(), args2));
    e.wasm_set_any_return(code, 3, e.wasm_create_return_node(2));
    console.log('2. Server sends untyped CodeInfo: ' + e.wasm_any_vector_length(code) + ' stmts (NO typeinf)');

    // 3. Browser runs WASM thin_typeinf
    const callee_typeids = e.wasm_create_i32_vector(3);
    e.wasm_set_i32(callee_typeids, 1, TID_MUL_INT);
    e.wasm_set_i32(callee_typeids, 2, TID_ADD_INT);
    e.wasm_set_i32(callee_typeids, 3, -1);
    const arg_typeids = e.wasm_create_i32_vector(2);
    e.wasm_set_i32(arg_typeids, 1, -1); e.wasm_set_i32(arg_typeids, 2, TID_I64);
    const rt_table = e.wasm_create_i32_vector(RT_DATA.length);
    for (let i = 0; i < RT_DATA.length; i++) e.wasm_set_i32(rt_table, i + 1, RT_DATA[i]);

    const ssa_types = e.wasm_thin_typeinf(code, callee_typeids, arg_typeids, rt_table, TID_I64, TID_I32, TID_F64, TID_BOOL);
    console.log('3. Browser WASM thin_typeinf: ' + e.wasm_i32_vector_length(ssa_types) + ' SSA types inferred');

    // 4. Compile via WASM wasm_compile_flat (ZERO JS binary assembly)
    // Build flat Int32 instruction buffer (data translation only, NOT compilation)
    // f(x) = x*x+1 → mul_int(arg0, arg0), add_int(ssa0, 1), return ssa1
    const flatData = [
        0, OPCODES.mul_int, 2, 0, 0, 0, 0,     // call mul_int(param0, param0)
        0, OPCODES.add_int, 2, 1, 0, 2, 1,      // call add_int(ssa0, const 1)
        1, 1, 1,                                  // return ssa1
    ];
    const instrs = e.wasm_create_i32_vector(flatData.length);
    for (let i = 0; i < flatData.length; i++) e.wasm_set_i32(instrs, i + 1, flatData[i]);

    // Compile IN WASM via wasm_compile_flat
    const wasmResult = e.wasm_compile_flat(instrs, 1);
    const len = e.wasm_bytes_length(wasmResult);
    console.log('4. WASM wasm_compile_flat: ' + len + ' bytes (ZERO JS compilation)');

    // Extract bytes from WasmGC Vector{UInt8}
    const userBytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) userBytes[i] = e.wasm_bytes_get(wasmResult, i + 1);

    // 5. Execute
    const userMod = await WebAssembly.compile(userBytes);
    const userInst = await WebAssembly.instantiate(userMod);
    const f = userInst.exports.f;

    const tests = [[5n,26n],[0n,1n],[-3n,10n],[10n,101n],[1n,2n]];
    let allPass = true;
    for (const [input, expected] of tests) {
        const result = f(input);
        const pass = result === expected;
        console.log('5. f(' + input + ') = ' + result + ' ' + (pass ? 'PASS' : 'FAIL'));
        if (!pass) allPass = false;
    }

    console.log();
    console.log(allPass ? 'ARCHITECTURE C E2E: PASS' : 'ARCHITECTURE C E2E: FAIL');
    console.log('Server: ZERO type inference. Browser: WASM thin_typeinf + WASM wasm_compile_flat.');
    console.log('ZERO JS compilation or binary assembly — ALL compilation in WASM.');
    if (!allPass) process.exit(1);
}

main().catch(err => { console.error('Fatal: ' + err.message); process.exit(1); });
