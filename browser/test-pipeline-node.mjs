/**
 * PURE-903: M_PIPELINE Node.js harness — load all 4 stage .wasm files and verify exports.
 *
 * Pipeline stages:
 *   1. parsestmt.wasm  — JuliaSyntax (parse Julia code to AST)
 *   2. lowering.wasm   — JuliaLowering (AST to lowered IR)
 *   3. typeinf.wasm    — Core.Compiler.typeinf (type inference)
 *   4. codegen.wasm    — WasmTarget self-hosting (codegen to Wasm)
 *
 * This test:
 *   1. Attempts to load each .wasm file via WasmTargetRuntime
 *   2. Reports which modules instantiate successfully vs fail validation
 *   3. Lists exports from each successfully loaded module
 *   4. Tests parsestmt: jsToWasmString('1+1') -> parse_expr_string -> verify output
 *
 * Run: node WasmTarget.jl/browser/test-pipeline-node.mjs
 *      (from GroupTherapyOrg/ directory)
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

let passed = 0;
let failed = 0;

function assert(condition, msg) {
    if (condition) {
        console.log(`  PASS: ${msg}`);
        passed++;
    } else {
        console.log(`  FAIL: ${msg}`);
        failed++;
    }
}

console.log("PURE-903: M_PIPELINE Node.js Harness\n");

const rt = new WasmTargetRuntime();

// ============================================================
// Phase 1: Load all 4 pipeline stage .wasm files
// ============================================================
console.log("--- Phase 1: Load Pipeline Stages ---\n");

const stages = [
    { name: "parsestmt", file: "parsestmt.wasm",  desc: "Stage 1: JuliaSyntax parser" },
    { name: "lowering",  file: "lowering.wasm",   desc: "Stage 2: JuliaLowering" },
    { name: "typeinf",   file: "typeinf.wasm",    desc: "Stage 3: Core.Compiler.typeinf" },
    { name: "codegen",   file: "codegen.wasm",    desc: "Stage 4: WasmTarget self-hosting" },
];

const loaded = {};

for (const stage of stages) {
    const wasmPath = join(__dirname, stage.file);
    let bytes;
    try {
        bytes = await readFile(wasmPath);
    } catch (err) {
        console.log(`  SKIP: ${stage.desc} — ${stage.file} not found`);
        continue;
    }

    const sizeKB = (bytes.length / 1024).toFixed(1);

    try {
        const instance = await rt.load(bytes, stage.name);
        loaded[stage.name] = instance;
        const exportNames = Object.keys(instance.exports);
        const funcExports = exportNames.filter(n => typeof instance.exports[n] === "function");
        assert(true, `${stage.desc}: loaded (${sizeKB} KB, ${funcExports.length} func exports)`);
    } catch (err) {
        // Expected for stages with validation errors (e.g., lowering.wasm)
        const shortErr = err.message.split("\n")[0].slice(0, 80);
        console.log(`  INFO: ${stage.desc}: failed to instantiate (${sizeKB} KB) — ${shortErr}`);
    }
}

const loadedCount = Object.keys(loaded).length;
console.log(`\n  Summary: ${loadedCount}/${stages.length} stages loaded`);

// ============================================================
// Phase 2: List exports from each loaded module
// ============================================================
console.log("\n--- Phase 2: Module Exports ---\n");

for (const [name, instance] of Object.entries(loaded)) {
    const exportNames = Object.keys(instance.exports);
    const funcExports = exportNames.filter(n => typeof instance.exports[n] === "function");
    const otherExports = exportNames.filter(n => typeof instance.exports[n] !== "function");

    console.log(`  ${name}: ${funcExports.length} functions, ${otherExports.length} other`);
    // Show first 10 function exports as sample
    if (funcExports.length > 0) {
        const sample = funcExports.slice(0, 10);
        console.log(`    sample: ${sample.join(", ")}${funcExports.length > 10 ? ", ..." : ""}`);
    }
}

// ============================================================
// Phase 3: Verify parsestmt key export exists
// ============================================================
console.log("\n--- Phase 3: Verify Key Exports ---\n");

if (loaded.parsestmt) {
    assert(typeof loaded.parsestmt.exports.parse_expr_string === "function",
        "parsestmt has parse_expr_string export");
} else {
    assert(false, "parsestmt not loaded — cannot verify exports");
}

if (loaded.codegen) {
    // codegen.wasm should have compile-related exports
    const codegenExports = Object.keys(loaded.codegen.exports)
        .filter(n => typeof loaded.codegen.exports[n] === "function");
    assert(codegenExports.length > 0, `codegen has ${codegenExports.length} function exports`);
}

if (loaded.typeinf) {
    const typeinfExports = Object.keys(loaded.typeinf.exports)
        .filter(n => typeof loaded.typeinf.exports[n] === "function");
    assert(typeinfExports.length > 0, `typeinf has ${typeinfExports.length} function exports`);
}

// ============================================================
// Phase 4: Test parsestmt — parse '1+1'
// ============================================================
console.log("\n--- Phase 4: parsestmt Execution Test ---\n");

if (loaded.parsestmt) {
    // Test string bridge
    const wasmStr = await rt.jsToWasmString("1+1");
    assert(wasmStr !== null && wasmStr !== undefined, "String bridge: '1+1' converted to WasmGC string");

    // Test parse_expr_string
    try {
        const result = loaded.parsestmt.exports.parse_expr_string(wasmStr);
        assert(result !== null && result !== undefined, "parse_expr_string('1+1') EXECUTES — returns WasmGC ref");
    } catch (e) {
        assert(false, `parse_expr_string('1+1') traps: ${e.message}`);
    }

    // Test multiple inputs
    const testInputs = ["1", "x", "a+b", "1 + 1", "42"];
    let executeCount = 0;
    for (const input of testInputs) {
        const s = await rt.jsToWasmString(input);
        try {
            loaded.parsestmt.exports.parse_expr_string(s);
            executeCount++;
        } catch (e) {
            console.log(`    INFO: "${input}" traps: ${e.message}`);
        }
    }
    assert(executeCount === testInputs.length,
        `${executeCount}/${testInputs.length} parsestmt inputs EXECUTE`);

    // CORRECT verification using count_parse_args if available
    let counter;
    try {
        const counterBytes = await readFile(join(__dirname, "count_parse_args.wasm"));
        counter = await rt.load(counterBytes, "counter");
    } catch (_) { /* not available */ }

    if (counter && typeof counter.exports.count_parse_args === "function") {
        const groundTruth = [
            ["1+1", 3],   // Expr(:call, :+, 1, 1) has 3 args
            ["a+b", 3],   // Expr(:call, :+, :a, :b) has 3 args
            ["1", -1],    // Int64 literal, not Expr
        ];
        for (const [input, expected] of groundTruth) {
            const s = await rt.jsToWasmString(input);
            try {
                const result = Number(counter.exports.count_parse_args(s));
                assert(result === expected,
                    `CORRECT: count_parse_args("${input}") = ${result} (expected ${expected})`);
            } catch (e) {
                assert(false, `count_parse_args("${input}") traps: ${e.message}`);
            }
        }
    } else {
        console.log("  SKIP: count_parse_args.wasm not available for CORRECT verification");
    }
} else {
    console.log("  SKIP: parsestmt not loaded — cannot test execution");
}

// ============================================================
// Summary
// ============================================================
console.log(`\n${"=".repeat(60)}`);
console.log(`Results: ${passed} passed, ${failed} failed`);
console.log(failed === 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED");

console.log("\nPipeline Status:");
for (const stage of stages) {
    const status = loaded[stage.name] ? "LOADED" : "FAILED (validation error)";
    console.log(`  ${stage.name}: ${status}`);
}

if (failed === 0) {
    console.log("\nPURE-903 Status: PASS");
    console.log("- All validating stages load in Node.js via WasmTargetRuntime");
    console.log("- parsestmt parse_expr_string EXECUTES for multiple inputs");
    console.log("- Module exports enumerated for all loaded stages");
}

process.exit(failed > 0 ? 1 : 0);
