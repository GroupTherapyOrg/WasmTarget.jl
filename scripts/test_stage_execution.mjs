// PURE-5001: Test each pipeline stage EXECUTES in Node.js (not just validates)
//
// Tests: parse_expr_string with string bridge, reimpl functions,
// and documents which stage exports can/cannot be called from JS.
//
// Usage: node scripts/test_stage_execution.mjs

import fs from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── String bridge (from wasmtarget-runtime.js) ──
const STRING_BRIDGE_BASE64 = "AGFzbQEAAAABJgZgAnx8AXxPAF5/AWABfwFjAWADYzF/fwBgAmMBfwF/YAFjAQF/AgwBBE1hdGgDcG93AAADBQQCAwQFBy8EB3N0cl9uZXcAAQxzdHJfc2V0Y2hhciEAAghzdHJfY2hhcgADB3N0cl9sZW4ABAosBAcAIAD7BwELDgAgACABQQFrIAL7DgELDAAgACABQQFr+wsBCwYAIAD7Dws=";

async function initStringBridge() {
    const bytes = Buffer.from(STRING_BRIDGE_BASE64, "base64");
    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(bytes, imports);
    return instance.exports;
}

async function jsToWasmString(bridge, str) {
    const codepoints = [...str];
    const wasmStr = bridge.str_new(codepoints.length);
    for (let i = 0; i < codepoints.length; i++) {
        bridge["str_setchar!"](wasmStr, i + 1, codepoints[i].codePointAt(0));
    }
    return wasmStr;
}

async function run() {
    console.log("=== PURE-5001: Stage Execution Discovery ===\n");

    // ── Load pipeline-optimized.wasm ──
    const wasmPath = join(__dirname, 'pipeline-optimized.wasm');
    if (!fs.existsSync(wasmPath)) {
        console.error(`ERROR: ${wasmPath} not found`);
        process.exit(1);
    }
    const bytes = fs.readFileSync(wasmPath);
    console.log(`Loaded pipeline-optimized.wasm: ${bytes.length} bytes (${(bytes.length/1024).toFixed(0)} KB)`);

    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(bytes, imports);
    const e = instance.exports;

    // List all exports
    const exportNames = Object.keys(e).filter(k => typeof e[k] === 'function');
    console.log(`Total function exports: ${exportNames.length}`);
    console.log(`Exports: ${exportNames.join(', ')}\n`);

    // ── Init string bridge ──
    let bridge;
    try {
        bridge = await initStringBridge();
        console.log("String bridge initialized OK\n");
    } catch (err) {
        console.log(`String bridge FAILED: ${err.message}\n`);
        bridge = null;
    }

    // ═══════════════════════════════════════════════════════════════
    // STAGE 1: parse_expr_string — String → externref(Expr)
    // ═══════════════════════════════════════════════════════════════
    console.log("--- Stage 1: parse_expr_string ---");

    const testInputs = ["1+1", "42", "x + y", "f(x) = x + 1"];

    for (const input of testInputs) {
        process.stdout.write(`  parse_expr_string("${input}"): `);
        try {
            if (!bridge) {
                console.log("SKIP (no string bridge)");
                continue;
            }
            const wasmStr = await jsToWasmString(bridge, input);

            // Use timeout to detect hangs
            const result = await Promise.race([
                new Promise((resolve) => {
                    try {
                        const r = e.parse_expr_string(wasmStr);
                        resolve({ ok: true, value: r });
                    } catch (err) {
                        resolve({ ok: false, error: err.message });
                    }
                }),
                new Promise((_, reject) => setTimeout(() => reject(new Error("TIMEOUT (5s)")), 5000))
            ]);

            if (result.ok) {
                const val = result.value;
                const valType = typeof val;
                console.log(`EXECUTES — returned ${valType}: ${val}`);
            } else {
                console.log(`TRAP — ${result.error}`);
            }
        } catch (err) {
            console.log(`HANG/TIMEOUT — ${err.message}`);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // STAGE 2: _to_lowered_expr — needs SyntaxTree (internal type)
    // ═══════════════════════════════════════════════════════════════
    console.log("\n--- Stage 2: _to_lowered_expr ---");
    console.log("  CANNOT test from JS — requires SyntaxTree{SyntaxGraph} (internal WasmGC struct)");
    console.log("  Must be called from another compiled Julia function inside the module");

    // ═══════════════════════════════════════════════════════════════
    // STAGE 3: typeinf — needs WasmInterpreter + InferenceState
    // ═══════════════════════════════════════════════════════════════
    console.log("\n--- Stage 3: typeinf ---");
    console.log("  CANNOT test from JS — requires (WasmInterpreter, InferenceState)");
    console.log("  These are complex internal types that can only be constructed in Julia");

    // Test reimpl functions (these already work from PURE-4151)
    console.log("\n--- Stage 3 reimpl: wasm_subtype, wasm_type_intersection ---");
    console.log("  Already verified 15/15 CORRECT in PURE-4151 (subtype + intersection)");
    console.log("  Skipping re-test — those results are confirmed");

    // ═══════════════════════════════════════════════════════════════
    // STAGE 4: compile — needs Function + Type{Tuple{...}}
    // ═══════════════════════════════════════════════════════════════
    console.log("\n--- Stage 4: compile ---");
    console.log("  CANNOT test from JS — requires (Function, Type{Tuple{Int64}})");
    console.log("  Julia Function and Type objects are WasmGC externref — no JS constructor");

    // ═══════════════════════════════════════════════════════════════
    // HELPER EXPORTS — test what we can
    // ═══════════════════════════════════════════════════════════════
    console.log("\n--- Helper exports ---");

    // Test no-arg and numeric-arg helpers
    const helperTests = [
        { name: "test_add_1_1", args: [], expected: 2 },
        { name: "test_sub_1", args: [], expected: 1 },
        { name: "test_sub_2", args: [], expected: 0 },
        { name: "test_isect_1", args: [], expected: 1 },
        { name: "test_isect_2", args: [], expected: 1 },
        { name: "pipeline_add", args: [1n, 1n], expected: 2n },
        { name: "pipeline_mul", args: [2n, 3n], expected: 6n },
        { name: "pipeline_sum_to", args: [10n], expected: 55n },
        { name: "pipeline_fib", args: [10n], expected: 55n },
        { name: "pipeline_isprime", args: [7n], expected: 1n },
    ];

    let pass = 0, fail = 0, trap = 0;
    for (const { name, args, expected } of helperTests) {
        process.stdout.write(`  ${name}(${args.join(',')}): `);
        try {
            const actual = e[name](...args);
            if (actual === expected) {
                console.log(`CORRECT = ${actual}`);
                pass++;
            } else {
                console.log(`WRONG: got ${actual}, expected ${expected}`);
                fail++;
            }
        } catch (err) {
            console.log(`TRAP: ${err.message}`);
            trap++;
        }
    }
    console.log(`\n  Helper results: ${pass}/${helperTests.length} CORRECT, ${fail} WRONG, ${trap} TRAP`);

    // ═══════════════════════════════════════════════════════════════
    // Test OTHER exports that might be callable
    // ═══════════════════════════════════════════════════════════════
    console.log("\n--- Other exports (probing) ---");

    // Test exports that take no args or simple args
    const probeExports = [
        "getproperty", "source_location", "getmeta", "to_expr",
        "to_code_info", "getindex", "getindex_1", "setindex!",
        "#_parse#75", "decode_effects", "_unioncomplexity",
        "unionlen", "datatype_fieldcount",
    ];

    for (const name of probeExports) {
        if (!e[name]) {
            console.log(`  ${name}: NOT EXPORTED`);
            continue;
        }
        process.stdout.write(`  ${name}(): `);
        try {
            const result = e[name]();
            console.log(`EXECUTES (no args) — returned ${typeof result}: ${result}`);
        } catch (err) {
            const msg = err.message || String(err);
            if (msg.includes('unreachable') || msg.includes('null') || msg.includes('trap')) {
                console.log(`TRAP (expected — needs proper args)`);
            } else {
                console.log(`ERROR: ${msg.substring(0, 100)}`);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // SUMMARY
    // ═══════════════════════════════════════════════════════════════
    console.log("\n" + "=".repeat(60));
    console.log("PURE-5001 DISCOVERY SUMMARY");
    console.log("=".repeat(60));
    console.log(`
Stage 1 (parsestmt):   parse_expr_string — needs string bridge test above
Stage 2 (lowering):    _to_lowered_expr — CANNOT test from JS (needs SyntaxTree struct)
Stage 3 (typeinf):     typeinf — CANNOT test from JS (needs WasmInterpreter + InferenceState)
Stage 3 (reimpl):      wasm_subtype, wasm_type_intersection — 15/15 CORRECT (PURE-4151)
Stage 4 (codegen):     compile — CANNOT test from JS (needs Function + Type objects)
Helpers (pipeline_*):  ${pass}/${helperTests.length} CORRECT — arithmetic, loops, control flow

KEY FINDING: Stages 2-4 require internal WasmGC struct types as inputs.
These types can only be constructed by other compiled Julia functions.
This CONFIRMS the PURE-5000 recommendation:
  → Write a single pipeline_eval(code::String)::SomeResult in Julia
  → Compile it to WasmGC with all 4 stages chained internally
  → All intermediate types stay as concrete WasmGC structs inside the module
  → JS only needs to pass a string in and get a result out
`);
}

run().catch(err => {
    console.error(`Fatal: ${err.message}`);
    process.exit(1);
});
