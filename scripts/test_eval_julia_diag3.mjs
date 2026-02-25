// PURE-6024 Agent 26: Deep diagnosis of should_include_node and _wasm_node_to_expr
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== Agent 26: Deep diagnosis ===\n");

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
            }
            return { status: 'ERROR', value: e.message || String(e) };
        }
    }

    // Test all the related diagnostics
    console.log("--- should_include_node and related ---");
    const tests = [
        'eval_julia_test_should_include',
        'eval_julia_test_not_should_include',
        'eval_julia_test_is_error',
        'eval_julia_test_has_toplevel',
        'eval_julia_test_cursor',
        'eval_julia_test_kind_string',
        'eval_julia_test_kind_eq',
    ];

    for (const name of tests) {
        const freshVec = jsToWasmBytes("1+1");
        const r = safeCall(name, freshVec);
        console.log(`  ${name}: ${r.status} → ${r.value}`);
    }

    // Now test _wasm_build_tree_expr steps individually
    // The issue: _wasm_build_tree_expr calls has_toplevel_siblings(cursor).
    // If TRUE: iterates reverse_toplevel_siblings, filters with should_include_node, calls _wasm_node_to_expr on CHILDREN
    // If FALSE: calls _wasm_node_to_expr on cursor directly (where should_include_node check is)
    //
    // The key: in the "else" branch, fixup_Expr_child wraps the result
    // In the "if" branch, it iterates children and calls _wasm_node_to_expr on each child

    // Check: does has_toplevel_siblings return true or false?

    console.log("\n--- All remaining eval_julia_test_* diagnostics ---");
    const allExports = Object.keys(E).filter(k => k.startsWith('eval_julia_test_'));
    for (const name of allExports.sort()) {
        const freshVec = jsToWasmBytes("1+1");
        const r = safeCall(name, freshVec);
        console.log(`  ${name}: ${r.status} → ${r.value}`);
    }
}

main().catch(e => { console.error(e); process.exit(1); });
