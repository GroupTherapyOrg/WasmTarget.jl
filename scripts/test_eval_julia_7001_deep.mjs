// PURE-7001 Agent 3: Deep isolation — test lexer/parser chain functions individually
// Goal: find exact function where trap occurs
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-7001: Deep Isolation — Lexer/Parser Chain ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);

    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const ex = instance.exports;

    // List ALL function exports for reference
    const funcExports = Object.keys(ex).filter(k => typeof ex[k] === 'function');
    console.log(`Total function exports: ${funcExports.length}\n`);

    // Helper: create WasmGC byte vec from JS string
    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    // Narrow test: call individual exported functions with a fresh ParseStream
    // _wasm_parse_statement! calls: parse_stmts(ParseState(ps)) + validate_tokens(ps)
    // parse_stmts calls: parse_Nary → __lookahead_index → _buffer_lookahead_tokens → next_token → _next_token

    console.log("--- Step 1: Create ParseStream ---");
    let ps;
    try {
        const v = jsToWasmBytes("1+1");
        ps = ex['ParseStream'](v);
        console.log(`  ParseStream: ${ps} — OK`);
    } catch (e) {
        console.log(`  ParseStream: TRAP — ${e.message}`);
        return;
    }

    // Test: Can we call Lexer? (Lexer is called during ParseStream construction
    // but also independently in the parser chain)
    console.log("\n--- Step 2: Test individual parser chain functions ---");

    // List interesting exports related to parsing
    const parserExports = funcExports.filter(k =>
        k.includes('parse') || k.includes('Parse') ||
        k.includes('Lexer') || k.includes('lexer') ||
        k.includes('token') || k.includes('Token') ||
        k.includes('next_') || k.includes('peek') ||
        k.includes('bump') || k.includes('lookahead') ||
        k.includes('_buffer') || k.includes('_Nary') ||
        k.includes('scan_')
    );
    console.log(`Parser-related exports (${parserExports.length}):`);
    for (const name of parserExports.sort()) {
        console.log(`  - ${name}`);
    }

    // Test parse_stmts with a fresh PS
    console.log("\n--- Step 3: Test _wasm_parse_statement! vs parse_stmts directly ---");

    // parse_stmts takes a ParseState, not ParseStream. We can't easily construct
    // a ParseState from JS. Instead, let's call _wasm_parse_statement! which
    // wraps parse_stmts and validate_tokens.

    // But we can test the diagnostic functions that are thinner wrappers:
    // _diag_stage0_ps creates ParseStream only (PASS)
    // _diag_stage0_parse creates ParseStream + _wasm_parse_statement! (TRAP)

    // What about calling _wasm_parse_statement! directly with a fresh PS?
    console.log("\n  Testing _wasm_parse_statement! with fresh ParseStream...");
    try {
        const v2 = jsToWasmBytes("1+1");
        const ps2 = ex['ParseStream'](v2);
        const r = ex['_wasm_parse_statement!'](ps2);
        console.log(`  _wasm_parse_statement!(ps) = ${r} — OK!`);
    } catch (e) {
        console.log(`  _wasm_parse_statement!(ps) = TRAP — ${e.message}`);

        // Get the stack trace if available
        if (e.stack) {
            const lines = e.stack.split('\n').slice(0, 10);
            console.log("  Stack trace:");
            for (const line of lines) {
                console.log(`    ${line}`);
            }
        }
    }

    // Test parse_stmts directly (if it takes ParseState not ParseStream,
    // this will likely trap with wrong types, but let's see)
    console.log("\n  Testing parse_stmts directly with ParseStream object...");
    try {
        const v3 = jsToWasmBytes("1+1");
        const ps3 = ex['ParseStream'](v3);
        const r = ex['parse_stmts'](ps3);
        console.log(`  parse_stmts(ps) = ${r} — OK!`);
    } catch (e) {
        console.log(`  parse_stmts(ps) = TRAP — ${e.message}`);
    }

    // Test validate_tokens directly
    console.log("\n  Testing validate_tokens directly...");
    try {
        const v4 = jsToWasmBytes("1+1");
        const ps4 = ex['ParseStream'](v4);
        const r = ex['validate_tokens'](ps4);
        console.log(`  validate_tokens(ps) = ${r} — OK!`);
    } catch (e) {
        console.log(`  validate_tokens(ps) = TRAP — ${e.message}`);
    }

    // Test the other lexer-related exports with dummy args to see which exist
    console.log("\n--- Step 4: Check which parser exports exist and their arity ---");
    const interestingFuncs = [
        'parse_stmts', 'parse_Nary', '_parser_stuck_error',
        '__lookahead_index', '_bump_until_n', 'Lexer',
        'validate_tokens', '_wasm_parse_statement!',
        'next_token', '_next_token', '_buffer_lookahead_tokens',
        'next_byte', 'peek_token', 'is_closing_token',
    ];
    for (const name of interestingFuncs) {
        const fn = ex[name];
        if (fn) {
            console.log(`  ${name}: EXISTS (length=${fn.length})`);
        } else {
            console.log(`  ${name}: NOT EXPORTED`);
        }
    }

    console.log("\n=== Done ===");
}

main().catch(e => { console.error(e); process.exit(1); });
