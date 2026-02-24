// Agent 22: Test all diagnostic functions — FRESH vector per call
// Root cause found: String(v::Vector{UInt8}) empties the source vector,
// so each test must use its own fresh vector to avoid contamination.
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const e = instance.exports;

    const makeByteVec = e['make_byte_vec'];
    const setByteVec = e['set_byte_vec!'];

    // Helper: create a fresh "1+1" vector
    function freshVec() {
        const str = "1+1";
        const bytes = new TextEncoder().encode(str);
        const v = makeByteVec(bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            setByteVec(v, i + 1, bytes[i]);
        }
        return v;
    }

    // All diagnostics that take Vector{UInt8}
    const diags = [
        'eval_julia_test_input_len',
        'eval_julia_test_array_nvals',
        'eval_julia_test_getindex_works',
        'eval_julia_test_ps_create',
        'eval_julia_test_parse_only',
        'eval_julia_test_string_from_bytes',
        'eval_julia_test_sourcefile',
        'eval_julia_test_textbuf',
        'eval_julia_test_cursor',
        'eval_julia_test_toplevel',
        'eval_julia_test_byte_range',
        'eval_julia_test_source_location',
        'eval_julia_test_child_count',
        'eval_julia_test_kind_string',
        'eval_julia_test_child_is_leaf',
        'eval_julia_test_child_byte_range',
        'eval_julia_test_child_head',
        'eval_julia_test_parse_literal',
        'eval_julia_test_child_br_broadcast',
        'eval_julia_test_uint32_getindex',
        'eval_julia_test_tree_nranges',
        'eval_julia_test_is_error',
        'eval_julia_test_should_include',
        'eval_julia_test_not_should_include',
        'eval_julia_test_manual_leaf_path',
        'eval_julia_test_untokenize',
        'eval_julia_test_untokenize_kind',
        'eval_julia_test_untokenize_kind_nouniq',
        'eval_julia_test_leaf_val',
        'eval_julia_test_leaf_node_to_expr',
        'eval_julia_test_node_to_expr_direct',
        'eval_julia_test_parseargs',
        'eval_julia_test_node_to_expr',
        'eval_julia_test_build_tree',
        'eval_julia_test_parse',
        'eval_julia_test_vec_in_struct',
        'eval_julia_test_textbuf_before_parse',
        'eval_julia_test_textbuf_first_byte',
        'eval_julia_test_ps_fields',
        'eval_julia_test_fresh_vec_len',
        'eval_julia_test_constant',
        'eval_julia_test_set_and_read',
        'eval_julia_test_set_read_chain',
        'eval_julia_test_make_set_read',
        'eval_julia_test_make_len',
    ];

    // Expected values for key diagnostics (native ground truth)
    const expected = {
        'eval_julia_test_input_len': 3,
        'eval_julia_test_array_nvals': 49,       // '1' = 49
        'eval_julia_test_getindex_works': 141,    // 49+43+49
        'eval_julia_test_ps_create': 1,
        'eval_julia_test_parse_only': 1,
        'eval_julia_test_string_from_bytes': 3,
        'eval_julia_test_textbuf': 3,
        'eval_julia_test_tree_nranges': 5,
        'eval_julia_test_child_count': 3,
        'eval_julia_test_kind_string': 4,         // "call" = 4 chars
        'eval_julia_test_is_error': 0,            // false
        'eval_julia_test_byte_range': 3,
        'eval_julia_test_source_location': 1,
        'eval_julia_test_textbuf_before_parse': 3,
        'eval_julia_test_textbuf_first_byte': 49,
        'eval_julia_test_constant': 42,
        'eval_julia_test_set_and_read': 99,
        'eval_julia_test_set_read_chain': 60,
        'eval_julia_test_make_set_read': 49,
        'eval_julia_test_make_len': 3,
        'eval_julia_test_fresh_vec_len': 5,
    };

    console.log("=== Diagnostic Results (fresh vector per call) ===\n");
    let pass = 0, fail = 0, unknown = 0;
    for (const name of diags) {
        const fn = e[name];
        if (!fn) {
            console.log(`  ${name}: NOT EXPORTED`);
            continue;
        }
        try {
            const vec = freshVec();
            const result = fn(vec);
            const exp = expected[name];
            let status = '';
            if (exp !== undefined) {
                if (result === exp) { status = ' ✓'; pass++; }
                else { status = ` ✗ (expected ${exp})`; fail++; }
            } else {
                unknown++;
            }
            console.log(`  ${name}: ${result}${status}`);
        } catch (err) {
            console.log(`  ${name}: ERROR — ${err.message}`);
            if (expected[name] !== undefined) fail++;
            else unknown++;
        }
    }

    // Special test: parse_3bytes takes (i32, i32, i32) not Vector{UInt8}
    console.log("\n=== Special Tests ===\n");
    const parse3 = e['eval_julia_test_parse_3bytes'];
    if (parse3) {
        try {
            const result = parse3(49, 43, 49); // "1+1"
            const exp = 3; // 3 args in call expr
            const status = result === exp ? '✓' : `✗ (expected ${exp})`;
            console.log(`  eval_julia_test_parse_3bytes(49,43,49): ${result} ${status}`);
            if (result === exp) pass++; else fail++;
        } catch (err) {
            console.log(`  eval_julia_test_parse_3bytes: ERROR — ${err.message}`);
            fail++;
        }
    } else {
        console.log("  eval_julia_test_parse_3bytes: NOT EXPORTED");
    }

    console.log(`\n=== Summary: ${pass} pass, ${fail} fail, ${unknown} unknown ===`);
}

main().catch(e => { console.error(e); process.exit(1); });
