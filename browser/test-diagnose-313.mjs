/**
 * PURE-313 Diagnostic: Detailed analysis of array bounds error
 *
 * The crash is at func 5 (_bump_until_n) offset 0x3754: array_get on lookahead array.
 * The position index is out of bounds.
 *
 * Strategy: Call individual exported functions to isolate where the issue starts.
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();

const wasmPath = join(__dirname, "parsestmt.wasm");
const wasmBytes = await readFile(wasmPath);
const parser = await rt.load(wasmBytes, "parsestmt");

console.log("=== PURE-313 Diagnostic ===\n");

// List all exports for reference
const exportNames = Object.keys(parser.exports).sort();
console.log(`Total exports: ${exportNames.length}`);

// 1. Test if ParseStream constructor works
console.log("\n--- Test 1: ParseStream constructor ---");
const wasmStr = await rt.jsToWasmString("1 + 1");
try {
    const ps = parser.exports.ParseStream(wasmStr);
    console.log("ParseStream created:", ps, typeof ps);
    if (ps && typeof ps === 'object') {
        console.log("  PS type:", ps.constructor?.name || 'unknown');
    }
} catch (e) {
    console.log("ParseStream FAILED:", e.message);
    if (e.stack) {
        // Extract just wasm function info
        const wasmLines = e.stack.split('\n').filter(l => l.includes('wasm-function'));
        wasmLines.forEach(l => console.log("  " + l.trim()));
    }
}

// 2. Test if Lexer constructor works
console.log("\n--- Test 2: Lexer constructor ---");
try {
    if (parser.exports.Lexer) {
        // Lexer takes an IOBuffer which we can't easily create
        console.log("Lexer export exists but needs IOBuffer param");
    }
} catch (e) {
    console.log("Lexer FAILED:", e.message);
}

// 3. Test __lookahead_index
console.log("\n--- Test 3: __lookahead_index ---");
try {
    if (parser.exports.__lookahead_index) {
        console.log("__lookahead_index exists, signature requires (stream, n, skip_newlines)");
    }
} catch (e) {
    console.log("__lookahead_index error:", e.message);
}

// 4. Test _buffer_lookahead_tokens
console.log("\n--- Test 4: _buffer_lookahead_tokens ---");
try {
    if (parser.exports._buffer_lookahead_tokens) {
        console.log("_buffer_lookahead_tokens exists");
    }
} catch (e) {
    console.log("_buffer_lookahead_tokens error:", e.message);
}

// 5. Try calling parse_expr_string with different input lengths
console.log("\n--- Test 5: Different inputs ---");
const inputs = ["1", "x", "1+1", "abc"];
for (const inp of inputs) {
    const ws = await rt.jsToWasmString(inp);
    try {
        const result = parser.exports.parse_expr_string(ws);
        console.log(`  "${inp}" → SUCCESS: ${result}`);
    } catch (e) {
        const msg = e.message || String(e);
        // Extract wasm function from stack
        const stackLines = (e.stack || '').split('\n').filter(l => l.includes('wasm-function'));
        const crashFunc = stackLines[0] ? stackLines[0].match(/wasm-function\[(\d+)\]:0x([0-9a-f]+)/)?.[0] : '';
        console.log(`  "${inp}" → ${msg} (${crashFunc})`);
    }
}

// 6. Check if next_token works in isolation
console.log("\n--- Test 6: next_token isolation ---");
try {
    if (parser.exports.next_token) {
        console.log("next_token export exists");
    } else {
        console.log("next_token not exported");
    }
} catch(e) {
    console.log("next_token error:", e.message);
}

// 7. List all pure i32 functions that work
console.log("\n--- Test 7: Working pure functions ---");
const pureFns = [
    'is_operator_start_char',
    'is_identifier_start_char',
    'is_never_id_char',
];
for (const name of pureFns) {
    const fn = parser.exports[name];
    if (fn) {
        try {
            const r = fn(43); // '+' = 43
            console.log(`  ${name}(43) = ${r}`);
        } catch(e) {
            console.log(`  ${name} FAILED: ${e.message}`);
        }
    }
}

console.log("\n=== Summary ===");
console.log("Crash: func 5 (_bump_until_n) offset 0x3754");
console.log("Root: array_get on lookahead[i-1] where i comes from local_8 (position parameter)");
console.log("Call: parse_atom passes local_813 as position (cached/stale value, path B)");
console.log("Or: __lookahead_index result (dynamic, path A)");
console.log("\nNext: Need to understand why the position value is out of bounds for the lookahead array");
