// PURE-6024 Agent 26: Test _wasm_build_tree_expr and pipeline steps
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== Agent 26: _wasm_build_tree_expr diagnostics ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    const imports = { Math: { pow: Math.pow } };
    const result = await WebAssembly.instantiate(wasmBytes, imports);
    const E = result.instance.exports;

    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = E['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            E['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    function safeCall(name, ...args) {
        try {
            const fn = E[name];
            if (!fn) return { status: 'MISSING', value: null };
            const val = fn(...args);
            return { status: 'OK', value: val };
        } catch (e) {
            if (e instanceof WebAssembly.Exception) {
                return { status: 'WASM_EXCEPTION', value: e.toString() };
            } else if (e instanceof WebAssembly.RuntimeError) {
                return { status: 'RUNTIME_ERROR', value: e.message };
            } else {
                return { status: 'JS_ERROR', value: e.message || String(e) };
            }
        }
    }

    // Test the WASM-specific functions that Agent 24 created
    console.log("--- Key _wasm_* diagnostics (fresh vec per call) ---");
    const wasmSpecific = [
        'eval_julia_test_build_tree_wasm',  // _wasm_build_tree_expr → should be 3 for "1+1"
        'eval_julia_test_direct_untokenize',  // _wasm_untokenize_kind
        'eval_julia_test_direct_untokenize_head',  // _wasm_untokenize_head
        'eval_julia_test_wasm_node_to_expr',  // _wasm_node_to_expr on top cursor
        'eval_julia_test_wasm_leaf',  // _wasm_leaf_to_expr
        'eval_julia_test_node_steps',  // step-by-step node_to_expr
        'eval_julia_test_untokenize_kind',
        'eval_julia_test_untokenize_kind_nouniq',
        'eval_julia_test_manual_leaf_path',
        'eval_julia_test_leaf_node_to_expr',
        'eval_julia_test_node_to_expr_direct',
    ];

    for (const name of wasmSpecific) {
        if (!E[name]) { console.log(`  ${name}: MISSING (not in exports)`); continue; }
        const freshVec = jsToWasmBytes("1+1");
        const r = safeCall(name, freshVec);
        console.log(`  ${name}: ${r.status} → ${r.value}`);
    }

    // Also test _wasm_build_tree_expr directly
    console.log("\n--- Direct _wasm_build_tree_expr call ---");
    if (E['_wasm_build_tree_expr']) {
        // This takes a ParseStream, not raw bytes. Can't call directly from JS.
        console.log("  _wasm_build_tree_expr: EXISTS (needs ParseStream input)");
    }

    // Test eval_julia_to_bytes_vec with more error detail
    console.log("\n--- eval_julia_to_bytes_vec with detailed error ---");
    for (const expr of ["1+1"]) {
        const freshVec = jsToWasmBytes(expr);
        try {
            const result = E.eval_julia_to_bytes_vec(freshVec);
            console.log(`  "${expr}": OK → ${result}`);
            const len = E.eval_julia_result_length(result);
            console.log(`    length: ${len}`);
        } catch (e) {
            console.log(`  "${expr}": ${e.constructor.name}`);
            if (e instanceof WebAssembly.Exception) {
                // Try to get tag info
                console.log(`    exception: ${e.toString()}`);
                try { console.log(`    is(): ${e.is(E.__wasm_exception_tag)}`); } catch {}
                try { console.log(`    getArg(0): ${e.getArg(E.__wasm_exception_tag, 0)}`); } catch (e2) {
                    console.log(`    getArg failed: ${e2.message}`);
                }
            } else {
                console.log(`    message: ${e.message}`);
                console.log(`    stack: ${e.stack?.split('\n').slice(0,3).join('\n')}`);
            }
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
