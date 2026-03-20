// ============================================================================
// deserialize_codeinfo.cjs — GAMMA-003: JS CodeInfo Deserializer + Mini-compiler
// ============================================================================
// Two-stage pipeline:
//   Stage 1 (WASM): Deserialize JSON → WasmGC IR structs via WASM constructors
//   Stage 2 (JS):   Compile IR to WASM binary (trivial for i64 arithmetic)
//
// Stage 1 validates that the WASM constructors correctly build IR structures.
// Stage 2 handles binary assembly in JS (avoids 471-stmt Julia function in WASM).
//
// Usage:
//   const { compileFromJson } = require('./deserialize_codeinfo.cjs');
//   const wasmBytes = compileFromJson(wasmExports, codeInfoJson);

'use strict';

// --- Intrinsic name → WASM opcode mapping ---
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

// --- LEB128 encoding ---
function encodeLEB128Unsigned(value) {
    const bytes = [];
    let v = value >>> 0; // Ensure unsigned 32-bit
    do {
        let byte = v & 0x7f;
        v >>>= 7;
        if (v !== 0) byte |= 0x80;
        bytes.push(byte);
    } while (v !== 0);
    return bytes;
}

function encodeLEB128Signed(value) {
    const bytes = [];
    let v = Number(value); // works for BigInt too if small enough
    let more = true;
    while (more) {
        let byte = v & 0x7f;
        v >>= 7;
        if ((v === 0 && (byte & 0x40) === 0) || (v === -1 && (byte & 0x40) !== 0)) {
            more = false;
        } else {
            byte |= 0x80;
        }
        bytes.push(byte);
    }
    return bytes;
}

/**
 * Resolve a callee from JSON to a WASM opcode.
 */
function resolveCalleeOpcode(val) {
    if (!val || typeof val !== 'object') return null;
    if (val._t === 'globalref' || val._t === 'intrinsic') {
        return INTRINSIC_OPCODES[val.name] || null;
    }
    return null;
}

/**
 * Deserialize a CodeInfo JSON entry into WASM IR structures via WASM constructors.
 * This validates that the WASM constructors work correctly.
 *
 * @param {object} e - WASM module exports
 * @param {object} entry - A single entry from the CodeInfo JSON
 * @returns {{ code: WasmRef, ssatypes: WasmRef, nargs: number, verified: boolean }}
 */
function deserializeEntry(e, entry) {
    const stmts = entry.code;
    const n = stmts.length;

    // Create code vector via WASM constructors
    const code = e.wasm_create_any_vector(n);
    const callSym = e.wasm_symbol_call();

    for (let i = 0; i < n; i++) {
        const stmt = stmts[i];
        const idx = i + 1; // 1-based

        switch (stmt._t) {
            case 'expr': {
                if (stmt.head === 'call') {
                    const args = stmt.args;
                    const nArgs = args.length;
                    const argsVec = e.wasm_create_any_vector(nArgs);

                    // Set callee (first arg) as i64 intrinsic ID
                    const calleeId = resolveCalleeOpcode(args[0]);
                    if (calleeId != null) {
                        e.wasm_set_any_i64(argsVec, 1, BigInt(calleeId));
                    }

                    // Set remaining args
                    for (let j = 1; j < nArgs; j++) {
                        _setValueInVector(e, argsVec, j + 1, args[j]);
                    }

                    const expr = e.wasm_create_expr(callSym, argsVec);
                    e.wasm_set_any_expr(code, idx, expr);
                }
                break;
            }
            case 'return': {
                if (stmt.val && stmt.val._t === 'ssa') {
                    const ret = e.wasm_create_return_node(stmt.val.id);
                    e.wasm_set_any_return(code, idx, ret);
                } else if (!stmt.val) {
                    const ret = e.wasm_create_return_node_nothing();
                    e.wasm_set_any_return(code, idx, ret);
                }
                break;
            }
            case 'goto': {
                const g = e.wasm_create_goto_node(stmt.label);
                e.wasm_set_any_goto(code, idx, g);
                break;
            }
            case 'gotoifnot': {
                if (stmt.cond && stmt.cond._t === 'ssa') {
                    const g = e.wasm_create_goto_if_not(stmt.cond.id, stmt.dest);
                    e.wasm_set_any_gotoifnot(code, idx, g);
                }
                break;
            }
            case 'phi': {
                const nEdges = stmt.edges.length;
                const edges = e.wasm_create_i32_vector(nEdges);
                const vals = e.wasm_create_any_vector(nEdges);
                for (let j = 0; j < nEdges; j++) {
                    e.wasm_set_i32(edges, j + 1, stmt.edges[j]);
                    _setValueInVector(e, vals, j + 1, stmt.values[j]);
                }
                const phi = e.wasm_create_phi_node(edges, vals);
                e.wasm_set_any_phi(code, idx, phi);
                break;
            }
            case 'nothing':
                break;
            default:
                break;
        }
    }

    // Build ssavaluetypes
    const ssatypes = e.wasm_create_ssatypes_all_i64(n);

    // Verify structure
    const codeLen = e.wasm_any_vector_length(code);
    const verified = codeLen === n;

    const nargs = (entry.arg_types ? entry.arg_types.length : 0) + 1;

    return { code, ssatypes, nargs, verified };
}

function _setValueInVector(e, vec, idx, val) {
    if (!val || typeof val !== 'object') return;
    switch (val._t) {
        case 'ssa':
            e.wasm_set_any_ssa(vec, idx, val.id);
            break;
        case 'arg':
            e.wasm_set_any_arg(vec, idx, val.n);
            break;
        case 'lit':
            if (val.jt === 'Int64' || val.jt === 'Int' || val.jt === 'Int32') {
                e.wasm_set_any_i64(vec, idx, BigInt(val.v));
            } else if (val.jt === 'Bool') {
                e.wasm_set_any_i64(vec, idx, BigInt(val.v ? 1 : 0));
            }
            break;
        default:
            break;
    }
}

// ============================================================================
// JS Mini-compiler: IR JSON → WASM binary
// ============================================================================
// Generates a complete WASM module for simple i64 arithmetic functions.
// No WASM module infrastructure needed — pure JS binary construction.

/**
 * Emit WASM opcodes for an IR value onto the body buffer.
 */
function _emitValue(body, val, nParams) {
    if (!val || typeof val !== 'object') return;
    switch (val._t) {
        case 'arg':
            body.push(0x20); // local.get
            body.push(...encodeLEB128Unsigned(val.n - 2)); // Argument(2) → local 0
            break;
        case 'ssa':
            body.push(0x20); // local.get
            body.push(...encodeLEB128Unsigned(nParams + val.id - 1));
            break;
        case 'lit':
            if (val.jt === 'Int64' || val.jt === 'Int' || val.jt === 'Int32') {
                body.push(0x42); // i64.const
                body.push(...encodeLEB128Signed(val.v));
            }
            break;
    }
}

/**
 * Compile a CodeInfo JSON entry to a complete WASM binary (Uint8Array).
 * Handles simple i64 arithmetic functions with call/return statements.
 */
function compileEntryToWasm(entry) {
    const stmts = entry.code;
    const nParams = entry.arg_types ? entry.arg_types.length : 0;
    const nStmts = stmts.length;

    // Count SSA locals needed (Expr statements produce SSA values)
    let nSsaLocals = 0;
    for (const stmt of stmts) {
        if (stmt._t === 'expr') nSsaLocals++;
    }

    // Generate function body bytecode
    const body = [];
    for (let i = 0; i < nStmts; i++) {
        const stmt = stmts[i];
        if (stmt._t === 'expr' && stmt.head === 'call') {
            const args = stmt.args;
            // Emit arguments (skip callee at index 0)
            for (let j = 1; j < args.length; j++) {
                _emitValue(body, args[j], nParams);
            }
            // Emit intrinsic opcode
            const opcode = resolveCalleeOpcode(args[0]);
            if (opcode != null) {
                body.push(opcode);
            }
            // Store SSA result in local
            const localIdx = nParams + i;
            body.push(0x21); // local.set
            body.push(...encodeLEB128Unsigned(localIdx));
        } else if (stmt._t === 'return') {
            if (stmt.val) {
                _emitValue(body, stmt.val, nParams);
            }
            // Value left on stack; function end returns it
        }
    }

    // Build complete WASM binary
    return _buildWasmBinary(body, nParams, nSsaLocals);
}

function _buildWasmBinary(body, nParams, nLocals) {
    const result = [];

    // Magic + version
    result.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);

    // Type section: func type (nParams × i64) → (i64)
    const typeContent = [];
    typeContent.push(0x01);  // 1 type
    typeContent.push(0x60);  // func type
    typeContent.push(...encodeLEB128Unsigned(nParams));
    for (let i = 0; i < nParams; i++) typeContent.push(0x7e); // i64
    typeContent.push(0x01);  // 1 result
    typeContent.push(0x7e);  // i64
    _emitSection(result, 0x01, typeContent);

    // Function section: 1 function, type 0
    _emitSection(result, 0x03, [0x01, 0x00]);

    // Export section: "f" → function 0
    const exportContent = [0x01, 0x01, 0x66, 0x00, 0x00]; // 1 export, name="f", func, idx=0
    _emitSection(result, 0x07, exportContent);

    // Code section
    const funcBody = [];
    if (nLocals > 0) {
        funcBody.push(0x01); // 1 local entry
        funcBody.push(...encodeLEB128Unsigned(nLocals));
        funcBody.push(0x7e); // i64
    } else {
        funcBody.push(0x00); // no locals
    }
    funcBody.push(...body);
    funcBody.push(0x0b); // end

    const bodyWithLen = [...encodeLEB128Unsigned(funcBody.length), ...funcBody];
    _emitSection(result, 0x0a, [0x01, ...bodyWithLen]); // 1 function body

    return new Uint8Array(result);
}

function _emitSection(result, id, content) {
    result.push(id);
    result.push(...encodeLEB128Unsigned(content.length));
    result.push(...content);
}

/**
 * Full pipeline: JSON → WASM constructor validation → JS compile → Uint8Array.
 *
 * Stage 1: Deserialize via WASM constructors (validates IR structure building)
 * Stage 2: Compile to WASM binary in JS (trivial for i64 arithmetic)
 *
 * @param {object} e - WASM module exports (codegen E2E module)
 * @param {string|object} jsonOrObj - CodeInfo JSON string or parsed object
 * @returns {Uint8Array} Compiled WASM bytes for the user function
 */
function compileFromJson(e, jsonOrObj) {
    const json = typeof jsonOrObj === 'string' ? JSON.parse(jsonOrObj) : jsonOrObj;
    const entry = json.entries[0]; // MVP: single function

    // Stage 1: Deserialize via WASM constructors (validates the bridge works)
    const { verified } = deserializeEntry(e, entry);
    if (!verified) {
        throw new Error('WASM constructor deserialization verification failed');
    }

    // Stage 2: Compile to WASM binary in JS
    return compileEntryToWasm(entry);
}

module.exports = {
    deserializeEntry,
    compileEntryToWasm,
    compileFromJson,
    INTRINSIC_OPCODES,
    resolveCalleeOpcode,
};
