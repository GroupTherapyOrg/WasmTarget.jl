/**
 * Trace test: Why does next_token return null?
 *
 * Strategy: Call individual exported functions to isolate where null comes from.
 * Func 19 (next_token) calls func 47 (_next_token).
 * Func 47 returns null Token (ref.null 39) for EOF_CHAR (-1).
 * We need to determine if chars[0] is wrong or if func 47 has a bug.
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

console.log("=== PURE-220 next_token null return trace ===\n");

// List all exported function names
const exports = Object.keys(parser.exports).filter(k => typeof parser.exports[k] === "function");
console.log(`Total exported functions: ${exports.length}`);

// Try to find next_token or _next_token in exports
const tokenFuncs = exports.filter(k => k.toLowerCase().includes("token") || k.toLowerCase().includes("lex"));
console.log(`Token-related exports: ${tokenFuncs.join(", ") || "none"}`);

// Try to find Lexer constructor
const lexFuncs = exports.filter(k => k.toLowerCase().includes("lex") || k.includes("Lexer"));
console.log(`Lexer-related exports: ${lexFuncs.join(", ") || "none"}`);

// Show first 30 exports
console.log(`\nFirst 30 exports: ${exports.slice(0, 30).join(", ")}`);

// Test: call _next_token (func 47) directly with a known Char value
// First we need to find what function index maps to what export name
console.log("\n=== Testing parse_expr_string with stack trace ===\n");

const inputs = ["1"];
for (const input of inputs) {
    const wasmStr = await rt.jsToWasmString(input);
    try {
        const result = parser.exports.parse_expr_string(wasmStr);
        console.log(`"${input}" -> success: ${result}`);
    } catch (e) {
        console.log(`"${input}" -> error: ${e.message}`);
        if (e.stack) {
            // Extract wasm function indices from stack
            const wasmFrames = e.stack.split('\n').filter(l => l.includes('wasm'));
            console.log(`Stack frames (${wasmFrames.length}):`);
            for (const frame of wasmFrames) {
                // Extract func index and offset
                const match = frame.match(/wasm-function\[(\d+)\].*?:(0x[0-9a-f]+)/);
                if (match) {
                    console.log(`  func ${match[1]} at offset ${match[2]}`);
                } else {
                    console.log(`  ${frame.trim()}`);
                }
            }
        }
    }
}

// Test: Try calling next_token (func 19) directly if exported
console.log("\n=== Testing exported functions directly ===\n");

// Check if _next_token is exported
if (parser.exports._next_token) {
    console.log("_next_token IS exported");
    try {
        // Try calling with a known non-EOF char
        // We'd need a Lexer struct though, can't call standalone
        console.log("Would need a Lexer struct to call _next_token");
    } catch (e) {
        console.log(`Error: ${e.message}`);
    }
} else {
    console.log("_next_token is NOT directly exported");
}

if (parser.exports.next_token) {
    console.log("next_token IS exported");
} else {
    console.log("next_token is NOT directly exported");
}

// Let's try to examine what's happening by looking at intermediate function results
// The issue is: func 19 (next_token) calls func 47 (_next_token) with chars[0]
// chars[0] comes from the chars tuple in the Lexer
// For the FIRST call after constructor, chars = (space, '1', EOF, EOF)
// next_token rotates: new_chars = ('1', EOF, EOF, readchar_result)
// _next_token receives new_chars[0] = old_chars[1] = '1' = 0x31000000

// But WAIT - in the constructor, chars[0] = space (0x20000000).
// The ParseStream constructor calls next_token(lexer, true) ZERO times.
// It's __lookahead_index (func 4) that calls _buffer_lookahead_tokens (func 11)
// which calls next_token (func 19).
//
// So the FIRST call to next_token gets start=true (i32.const 1).
// With start=true:
//   - sets token_startpos from charpos
//   - checks string_states.size == 0 → normal path
//   - does readchar from IOBuffer
//   - rotates chars
//   - calls _next_token(lexer, new_chars[0])
//
// new_chars[0] = old_chars[1]. In the constructor, chars[1] was the FIRST read char.
// For input "1": first read = Char('1') = 0x31000000.
// BUT WAIT: the constructor also reads chars for the Lexer!
// The Lexer constructor reads 3 chars: chars = (' ', read1, read2, read3)
// For input "1" (1 byte): read1 = '1' (0x31000000), read2 = EOF, read3 = EOF
//
// Then next_token does ANOTHER readchar and rotates:
// new_chars = (read1, read2, read3, readchar_result) = ('1', EOF, EOF, EOF)
// _next_token receives '1' (0x31000000)
//
// '1' != -1 (EOF_CHAR), so it should NOT return null.

// So what else could return null from _next_token?
// The function has many ref.null 39 instructions for default local init.
// But the FIRST one at relative line 137 (absolute ~110050) is the EOF check.
// After that, the function classifies the char and dispatches.
// For '1' (digit), it should go to the number tokenizer path.

// Let me check: what happens for 0x31000000 in the br_if cascading checks?
// 0x31000000 = Char('1')
// After the UTF-8 validation (is it a valid char?), it enters the category dispatch:
// - 0x20000000 = ' ' (space/newline category?)
// - 0x09000000 = '\t'
// - 0x0D000000 = '\r'
// - 0x0A000000 = '\n' = 167772160
// - 0x30000000 to 0x39000000 = '0'-'9' (digits)
//
// 0x31000000 = 822083584
// 0x30000000 = 805306368
// 0x39000000 = 956301312
//
// So '1' (0x31000000) is in the digit range.
// The tokenizer should recognize it as a numeric literal.

// To actually trace, let's use a different approach:
// Compile a simpler function that just tokenizes and returns the first token kind

console.log("\n=== Verifying char values ===\n");
console.log(`Char(' ') = 0x${(0x20000000).toString(16)} = ${0x20000000}`);
console.log(`Char('1') = 0x${(0x31000000).toString(16)} = ${0x31000000}`);
console.log(`Char('0') = 0x${(0x30000000).toString(16)} = ${0x30000000}`);
console.log(`Char('9') = 0x${(0x39000000).toString(16)} = ${0x39000000}`);
console.log(`EOF_CHAR  = 0x${(0xFFFFFFFF).toString(16)} = ${-1}`);

// Check if any i32 pure functions can help us trace
// is_operator_start_char works - let's try more
const charFuncs = exports.filter(k => k.includes("char") || k.includes("is_"));
console.log(`\nChar classification exports: ${charFuncs.join(", ") || "none"}`);

for (const fn of charFuncs.slice(0, 10)) {
    try {
        const result = parser.exports[fn](0x31000000); // '1'
        console.log(`  ${fn}(Char('1')) = ${result}`);
    } catch (e) {
        // Some functions need more args
    }
}

process.exit(0);
