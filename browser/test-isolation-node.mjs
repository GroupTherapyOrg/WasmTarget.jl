/**
 * Isolation testing for parsestmt hang diagnosis (PURE-317)
 * Fixed: Uses reinterpret(Int16, Kind) instead of Int32(Kind)
 */
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

async function testModule(wasmPath, funcName, input, expected) {
    const rt = new WasmTargetRuntime();
    try {
        const wasmBytes = await readFile(wasmPath);
        const mod = await rt.load(wasmBytes, funcName);
        const fn = mod.exports[funcName];
        if (!fn) {
            const exports = Object.keys(mod.exports).filter(k => typeof mod.exports[k] === "function");
            console.log(`  SKIP: ${funcName} not exported. Available: ${exports.slice(0, 10).join(", ")}`);
            return "skip";
        }
        let wasmInput = typeof input === "string" ? await rt.jsToWasmString(input) : input;
        try {
            const r = fn(wasmInput);
            const pass = expected === undefined || r === expected;
            console.log(`  ${pass ? "PASS" : "FAIL"}: ${funcName}(${JSON.stringify(input)}) = ${r}${expected !== undefined ? ` (expected ${expected})` : ""}`);
            return pass ? "pass" : "fail";
        } catch (e) {
            console.log(`  TRAP: ${funcName}(${JSON.stringify(input)}): ${e.message || e}`);
            return "trap";
        }
    } catch (e) {
        console.log(`  ERROR: load ${wasmPath} — ${e.message}`);
        return "error";
    }
}

console.log("=== Isolation Testing for PURE-317 (Fixed) ===\n");

// Step 1: Basic Lexer construction
console.log("Step 1: lex_first_char — Lexer chars[2] after construction");
await testModule("/tmp/test_lex_first_char.wasm", "lex_first_char", "1", 49);  // '1' = 49
await testModule("/tmp/test_lex_first_char.wasm", "lex_first_char", " ", 32);  // ' ' = 32

// Step 2: readchar from Lexer
console.log("\nStep 2: lex_readchar — Tokenize.readchar(lexer)");
await testModule("/tmp/test_lex_readchar.wasm", "lex_readchar", "1", 49);

// Step 3: Sub-operations of emit (all fixed with reinterpret)
console.log("\nStep 3: Sub-operations of emit");
await testModule("/tmp/test_startpos.wasm", "test_startpos", "1", undefined);
await testModule("/tmp/test_position.wasm", "test_position", "1", undefined);
await testModule("/tmp/test_rawtoken.wasm", "test_rawtoken", "1", 1);  // Whitespace=1

// Step 4: emit (constructs RawToken + suffix logic)
console.log("\nStep 4: test_emit — emit(lexer, Whitespace)");
await testModule("/tmp/test_emit.wasm", "test_emit", "1", 1);  // Whitespace=1

// Step 5: lex_whitespace direct call
console.log("\nStep 5: test_lex_ws — lex_whitespace(lexer, ' ')");
await testModule("/tmp/test_lex_ws.wasm", "test_lex_ws", "1", 1);  // Whitespace=1

// Step 6: Full next_token with various inputs
console.log("\nStep 6: lex_raw_kind — full next_token");
await testModule("/tmp/test_lex_raw_kind.wasm", "lex_raw_kind", "1", 44);     // Integer=44
await testModule("/tmp/test_lex_raw_kind.wasm", "lex_raw_kind", " ", 1);      // Whitespace=1
await testModule("/tmp/test_lex_raw_kind.wasm", "lex_raw_kind", "abc", 3);    // Identifier=3
await testModule("/tmp/test_lex_raw_kind.wasm", "lex_raw_kind", "+", undefined);  // Plus
await testModule("/tmp/test_lex_raw_kind.wasm", "lex_raw_kind", "(", undefined);  // LParen

// Step 7: Full next_token_space (next_token with space handling)
console.log("\nStep 7: test_next_token_space — next_token with space handling");
await testModule("/tmp/test_next_token_space.wasm", "test_next_token_space", "1", 44);    // Integer=44
await testModule("/tmp/test_next_token_space.wasm", "test_next_token_space", " 1", undefined);
await testModule("/tmp/test_next_token_space.wasm", "test_next_token_space", "1+1", 44);  // Integer=44

console.log("\n=== Done ===");
