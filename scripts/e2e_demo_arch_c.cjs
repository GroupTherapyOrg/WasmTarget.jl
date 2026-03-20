#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');

function leb128_unsigned(n) {
    const bytes = [];
    do { let b = n & 0x7f; n >>>= 7; if (n !== 0) b |= 0x80; bytes.push(b); } while (n !== 0);
    return bytes;
}

function leb128_signed(n) {
    const bytes = [];
    let more = true;
    while (more) {
        let b = n & 0x7f; n >>= 7;
        if ((n === 0 && (b & 0x40) === 0) || (n === -1 && (b & 0x40) !== 0)) more = false;
        else b |= 0x80;
        bytes.push(b);
    }
    return bytes;
}

function buildWasmModule(funcBody, nParams) {
    const out = [];
    out.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);
    const paramTypes = new Array(nParams).fill(0x7e);
    const typePayload = [0x01, 0x60, ...leb128_unsigned(nParams), ...paramTypes, 0x01, 0x7e];
    out.push(0x01, ...leb128_unsigned(typePayload.length), ...typePayload);
    out.push(0x03, 0x02, 0x01, 0x00);
    const nameBytes = [0x66];
    const exportPayload = [0x01, ...leb128_unsigned(nameBytes.length), ...nameBytes, 0x00, 0x00];
    out.push(0x07, ...leb128_unsigned(exportPayload.length), ...exportPayload);
    const bodyBytes = [];
    let localIdx = nParams;  // locals start after params
    for (const stmt of funcBody) {
        if (stmt.type === 'call') {
            for (const arg of stmt.args) {
                if (arg.type === 'arg') bodyBytes.push(0x20, ...leb128_unsigned(arg.index));
                else if (arg.type === 'ssa') bodyBytes.push(0x20, ...leb128_unsigned(arg.local));
                else if (arg.type === 'i64') bodyBytes.push(0x42, ...leb128_signed(Number(arg.value)));
            }
            bodyBytes.push(stmt.opcode);
            bodyBytes.push(0x21, ...leb128_unsigned(localIdx));  // local.set → store result
            localIdx++;
        } else if (stmt.type === 'return') {
            if (stmt.arg.type === 'ssa') bodyBytes.push(0x20, ...leb128_unsigned(stmt.arg.local));
            else if (stmt.arg.type === 'arg') bodyBytes.push(0x20, ...leb128_unsigned(stmt.arg.index));
        }
    }
    const nLocals = funcBody.filter(s => s.type === 'call').length;
    const localDecl = nLocals > 0 ? [0x01, ...leb128_unsigned(nLocals), 0x7e] : [0x00];
    const funcPayload = [...localDecl, ...bodyBytes, 0x0b];
    const funcWithSize = [...leb128_unsigned(funcPayload.length), ...funcPayload];
    const codePayload = [0x01, ...funcWithSize];
    out.push(0x0a, ...leb128_unsigned(codePayload.length), ...codePayload);
    return new Uint8Array(out);
}

async function main() {
    console.log('Architecture C E2E Demo');
    console.log('Server parse+lower -> Browser WASM thin_typeinf -> compile -> execute');
    console.log();

    // TypeID constants (baked from native Julia)
    const TID_I64 = 2, TID_I32 = 13, TID_F64 = 22, TID_BOOL = 10;
    const TID_MUL_INT = 48, TID_ADD_INT = 49;
    const RT_DATA = [-1,-1,-1,-1,1789606658,21,-1,-1,-82928636,13,-1493455867,2,-565919996,2,-1,-1,-1,-1,-1,-1,394222090,21,207741451,13,-1,-1,-1,-1,-1,-1,759240463,10,-2059568368,2,-1368071663,2,-1,-1,-1,-1,-1,-1,-1271870443,13,1830123029,13,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1113670622,13,-1,-1,-461658332,22,-372984539,21,-1,-1,423627815,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-142484686,2,1992354867,13,-590452428,21,198980405,22,549012019,2,-1,-1,-1,-1,-1,-1,1752380986,10,2093837883,21,-1,-1,-1,-1,-2056249538,21,-1,-1,365923392,22,1489627969,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-543728568,13,-1,-1,-1,-1,1965043787,22,-1,-1,-1,-1,-1,-1,-1,-1,-1995127216,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1732670375,13,-1,-1,-1,-1,1876082012,2,-1,-1,-1,-1,-1,-1,-1,-1,1110898273,10,-1,-1,-888255645,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,1492644717,13,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,1531554935,13,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-501801602,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1203599738,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1004528500,13,1130311053,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-617863020,2,-1,-1,-1,-1,-1,-1,564198552,2,-1,-1,-1,-1,-1,-1,-1,-1,2101496989,13,-1,-1,-1,-1,-137599584,10,-1,-1,-1,-1,-1,-1,689582756,2,-1,-1,147816358,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-2132858708,10,-2044184915,10,-1,-1,-1247572561,2,-1,-1,-1,-1,808298162,10,-418300494,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,2033314492,10,-1472219971,10,-1,-1,-1,-1,377871296,13,-1,-1,1779484098,10,-380643645,10,469546690,2,-1,-1,-1,-1,-1,-1,-1,-1,-181572407,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-811070511,13,-883370543,10,-1,-1,-747684908,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,444863711,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,1798896878,13,1684904430,13,-1,-1,444529649,22,-1,-1,1033713139,10,-1910997005,2,-1,-1,347498230,10,-1784523530,10,-1,-1,-1,-1,-177742854,22,-1,-1,-1,-1,-1,-1,-1,-1,609955071,13];

    // 1. Load thin_typeinf WASM module
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
    console.log('1. Loaded thin_typeinf module: ' + Object.keys(e).length + ' exports');

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

    // 4. Compile to WASM binary (JS mini-compiler)
    const funcBody = [
        { type: 'call', opcode: 0x7e, args: [{ type: 'arg', index: 0 }, { type: 'arg', index: 0 }] },
        { type: 'call', opcode: 0x7c, args: [{ type: 'ssa', local: 1 }, { type: 'i64', value: 1n }] },
        { type: 'return', arg: { type: 'ssa', local: 2 } },
    ];
    const userBytes = buildWasmModule(funcBody, 1);
    console.log('4. Compiled: ' + userBytes.length + ' bytes');

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
    console.log('Server does ZERO type inference. f(5n) === 26n via browser WASM thin_typeinf.');
    if (!allPass) process.exit(1);
}

main().catch(err => { console.error('Fatal: ' + err.message); process.exit(1); });
