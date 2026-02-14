// Test parse_julia_literal directly
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rc = fs.readFileSync(path.join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

(async () => {
    const rt = new WRT();
    const w = fs.readFileSync(path.join(__dirname, 'parsestmt.wasm'));
    const pa = await rt.load(w, 'parsestmt');
    const ex = pa.exports;

    // parse_julia_literal is func 41
    // type (;136;) (func (param (ref null 6) (ref null 14) (ref null 14)) (result externref))
    // param0: ref null 6 = Vector{UInt8} (text bytes)
    // param1: ref null 14 = SyntaxHead
    // param2: ref null 14 = UnitRange{UInt32} (byte range)

    // We can't call it directly from JS because we can't construct WasmGC structs.
    // But we CAN trace through the full pipeline.

    // Instead, let's see what parse_expr_string does step by step for "1"
    // by looking at intermediate function results.

    // The key question: does parse_expr_string("1") properly call parse_julia_literal?
    // Let's check if _node_to_expr is called (it's the non-leaf path)
    // vs the direct return path

    console.log("=== Testing parse_expr_string with different inputs ===");
    const inputs = ['1', '42', '100', 'true', 'false', 'x', '+', '1+1'];
    for (const input of inputs) {
        const s = await rt.jsToWasmString(input);
        try {
            const result = ex.parse_expr_string(s);
            console.log(`  "${input}" => ${result} (${typeof result}, null=${result===null})`);
        } catch (e) {
            console.log(`  "${input}" => ERROR: ${e.message}`);
        }
    }

    // Check what diag_output_len returns (if it exists)
    if (typeof ex.diag_output_len === 'function') {
        console.log("\n=== Testing diag_output_len ===");
        for (const input of ['1', '1+1']) {
            const s = await rt.jsToWasmString(input);
            try {
                const result = ex.diag_output_len(s);
                console.log(`  diag_output_len("${input}") => ${result}`);
            } catch (e) {
                console.log(`  diag_output_len("${input}") => ERROR: ${e.message}`);
            }
        }
    }

    // Check _node_to_expr
    if (typeof ex._node_to_expr === 'function') {
        console.log("\n_node_to_expr exists as export");
    }
})();
