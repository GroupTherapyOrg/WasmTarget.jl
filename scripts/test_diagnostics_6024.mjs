// Agent 23: Test ALL diagnostic exports from eval_julia.wasm
// Each test gets a FRESH byte vector to avoid the String(Vector{UInt8}) emptying issue

import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== Agent 23: Diagnostic tests for eval_julia.wasm ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    console.log(`Module size: ${wasmBytes.length} bytes`);

    const imports = { Math: { pow: Math.pow } };
    const result = await WebAssembly.instantiate(wasmBytes, imports);
    const e = result.instance.exports;

    const funcExports = Object.keys(e).filter(k => typeof e[k] === 'function');
    console.log(`Function exports: ${funcExports.length}`);
    console.log(`Exports: ${funcExports.join(', ')}\n`);

    const makeByteVec = e['make_byte_vec'];
    const setByteVec = e['set_byte_vec!'];

    function freshBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = makeByteVec(bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            setByteVec(vec, i + 1, bytes[i]);
        }
        return vec;
    }

    // Test each diagnostic export with a fresh vector
    const tests = [
        'eval_julia_test_input_len',
        'eval_julia_test_fresh_vec_len',
        'eval_julia_test_constant',
        'eval_julia_test_set_and_read',
        'eval_julia_test_set_read_chain',
        'eval_julia_test_make_set_read',
        'eval_julia_test_make_len',
        'eval_julia_test_array_nvals',
        'eval_julia_test_getindex_works',
        'eval_julia_test_string_from_bytes',
        'eval_julia_test_parse_int',
        'eval_julia_test_vec_in_struct',
        'eval_julia_test_ps_create',
        'eval_julia_test_parse_only',
        'eval_julia_test_textbuf',
        'eval_julia_test_textbuf_first_byte',
        'eval_julia_test_textbuf_before_parse',
        'eval_julia_test_ps_fields',
        'eval_julia_test_tree_nranges',
        'eval_julia_test_cursor',
        'eval_julia_test_sourcefile',
        'eval_julia_test_toplevel',
        'eval_julia_test_byte_range',
        'eval_julia_test_source_location',
        'eval_julia_test_child_count',
        'eval_julia_test_child_is_leaf',
        'eval_julia_test_child_byte_range',
        'eval_julia_test_child_head',
        'eval_julia_test_is_error',
        'eval_julia_test_kind_string',
        'eval_julia_test_should_include',
        'eval_julia_test_not_should_include',
        'eval_julia_test_parse_literal',
        'eval_julia_test_child_br_broadcast',
        'eval_julia_test_uint32_getindex',
        'eval_julia_test_untokenize',
        'eval_julia_test_untokenize_kind',
        'eval_julia_test_untokenize_kind_nouniq',
        'eval_julia_test_manual_leaf_path',
        'eval_julia_test_leaf_val',
        'eval_julia_test_leaf_node_to_expr',
        'eval_julia_test_node_to_expr_direct',
        'eval_julia_test_node_to_expr',
        'eval_julia_test_parseargs',
        'eval_julia_test_build_tree',
        'eval_julia_test_parse',
    ];

    // Expected values from Agent 22 + native Julia
    const expected = {
        'eval_julia_test_input_len': 3,
        'eval_julia_test_fresh_vec_len': 5,
        'eval_julia_test_constant': 42,
        'eval_julia_test_set_and_read': 99,
        'eval_julia_test_set_read_chain': 60,
        'eval_julia_test_make_set_read': 49,
        'eval_julia_test_make_len': 3,
        'eval_julia_test_array_nvals': 49,
        'eval_julia_test_getindex_works': 141,
        'eval_julia_test_string_from_bytes': 3,
        'eval_julia_test_parse_int': null, // depends on input
        'eval_julia_test_vec_in_struct': 3,
        'eval_julia_test_ps_create': 1,
        'eval_julia_test_parse_only': 1,
        'eval_julia_test_textbuf': 3,
        'eval_julia_test_textbuf_first_byte': 49,
        'eval_julia_test_textbuf_before_parse': 3,
        'eval_julia_test_ps_fields': 30504,
        'eval_julia_test_tree_nranges': 5,
        'eval_julia_test_cursor': 1,
        'eval_julia_test_sourcefile': 1,
        'eval_julia_test_toplevel': 0,
        'eval_julia_test_byte_range': 3,
        'eval_julia_test_source_location': 1,
        'eval_julia_test_child_count': 3,
        'eval_julia_test_child_is_leaf': 1,
        'eval_julia_test_child_byte_range': 1,
        'eval_julia_test_child_head': 1,
        'eval_julia_test_is_error': 0,
        'eval_julia_test_kind_string': 4,
        'eval_julia_test_should_include': 100,
        'eval_julia_test_not_should_include': 10,
        'eval_julia_test_parse_literal': 1,
        'eval_julia_test_child_br_broadcast': 1,
        'eval_julia_test_uint32_getindex': 1,
        'eval_julia_test_untokenize': 4,  // "call" has length 4
        'eval_julia_test_untokenize_kind': 4,  // "call" should have length 4
        'eval_julia_test_untokenize_kind_nouniq': 4,  // same
        'eval_julia_test_manual_leaf_path': 42,
        'eval_julia_test_leaf_val': 3,  // 3 leaf children for "1+1"
        'eval_julia_test_leaf_node_to_expr': 1,
        'eval_julia_test_node_to_expr_direct': 3,  // 3 args for :call
        'eval_julia_test_node_to_expr': 42,
        'eval_julia_test_parseargs': 3,
        'eval_julia_test_build_tree': 42,
        'eval_julia_test_parse': 3,
    };

    console.log("--- Running diagnostics (each with fresh vector for '1+1') ---\n");
    let pass = 0, fail = 0, error = 0;

    for (const name of tests) {
        const fn = e[name];
        if (!fn) {
            console.log(`  ${name}: MISSING EXPORT`);
            error++;
            continue;
        }
        try {
            // Special case: parse_3bytes takes 3 int args
            let result;
            if (name === 'eval_julia_test_parse_3bytes') {
                result = fn(49, 43, 49); // '1', '+', '1'
            } else {
                const vec = freshBytes("1+1");
                result = fn(vec);
            }
            const exp = expected[name];
            const ok = exp !== null && exp !== undefined ? result === exp : true;
            const statusStr = exp !== null && exp !== undefined
                ? (ok ? 'OK' : `FAIL (expected ${exp})`)
                : 'OK (no expected)';
            console.log(`  ${name}: ${result} — ${statusStr}`);
            if (ok) pass++; else fail++;
        } catch (err) {
            console.log(`  ${name}: ERROR — ${err.message}`);
            error++;
        }
    }

    // Also test parse_3bytes if it exists
    if (e['eval_julia_test_parse_3bytes']) {
        try {
            const result = e['eval_julia_test_parse_3bytes'](49, 43, 49);
            const ok = result === 3;
            console.log(`  eval_julia_test_parse_3bytes(49,43,49): ${result} — ${ok ? 'OK' : `FAIL (expected 3)`}`);
            if (ok) pass++; else fail++;
        } catch (err) {
            console.log(`  eval_julia_test_parse_3bytes: ERROR — ${err.message}`);
            error++;
        }
    }

    console.log(`\n=== Summary: ${pass} pass, ${fail} fail, ${error} error ===`);
}

main().catch(e => { console.error(e); process.exit(1); });
