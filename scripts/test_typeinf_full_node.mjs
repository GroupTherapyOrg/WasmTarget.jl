// PURE-4153: Test typeinf_full.wasm wrapper functions for correctness
// Tests the 8 existing test wrappers (test_sub_1..5, test_isect_1..3)
// All return Int32: 1 = true, 0 = false

import fs from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const wasmPath = path.join(__dirname, 'typeinf_full.wasm');
const bytes = fs.readFileSync(wasmPath);

async function run() {
    try {
        const importObject = { Math: { pow: Math.pow } };
        const wasmModule = await WebAssembly.instantiate(bytes, importObject);
        const exports = wasmModule.instance.exports;

        console.log("Module loaded OK");
        console.log("Exports:", Object.keys(exports).filter(k => k.startsWith('test_')).join(", "));

        // Test cases: [export_name, expected_result, description]
        const tests = [
            ["test_sub_1", 1, "Int64 <: Number → true"],
            ["test_sub_2", 0, "Int64 <: String → false"],
            ["test_sub_3", 1, "Float64 <: Real → true"],
            ["test_sub_4", 1, "String <: Any → true"],
            ["test_sub_5", 0, "Any <: Int64 → false"],
            ["test_isect_1", 1, "Int64 ∩ Number === Int64 → true"],
            ["test_isect_2", 1, "Int64 ∩ String === Union{} → true"],
            ["test_isect_3", 1, "Number ∩ Real === Real → true"],
        ];

        let pass = 0;
        let fail = 0;
        let error = 0;

        for (const [name, expected, desc] of tests) {
            try {
                const result = exports[name]();
                if (result === expected) {
                    console.log(`  ${name}: ${result} — CORRECT ✓  (${desc})`);
                    pass++;
                } else {
                    console.log(`  ${name}: ${result} — MISMATCH ✗ (expected ${expected}, ${desc})`);
                    fail++;
                }
            } catch (e) {
                console.log(`  ${name}: ERROR — ${e.message}`);
                error++;
            }
        }

        console.log(`\nResults: ${pass}/${tests.length} CORRECT, ${fail} MISMATCH, ${error} ERROR`);
        if (pass === tests.length) {
            console.log("ALL CORRECT (level 3) ✓");
        }

        // Also check that non-test exports exist (module integrity)
        const keyExports = ['wasm_subtype', '_subtype', 'wasm_type_intersection', '_intersect', 'wasm_matching_methods', 'typeinf'];
        const missing = keyExports.filter(k => !(k in exports));
        if (missing.length > 0) {
            console.log(`\nWARNING: Missing key exports: ${missing.join(', ')}`);
        } else {
            console.log(`\nAll ${keyExports.length} key exports present ✓`);
        }

    } catch (e) {
        console.log("INSTANTIATION ERROR:", e.message);
        if (e.stack) console.log("Stack:", e.stack);
        process.exit(1);
    }
}

run();
