// Agent 22: Test all diagnostic functions to understand what works/breaks
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

    // Create byte vector for "1+1"
    const makeByteVec = e['make_byte_vec'];
    const setByteVec = e['set_byte_vec!'];
    const str = "1+1";
    const bytes = new TextEncoder().encode(str);
    const vec = makeByteVec(bytes.length);
    for (let i = 0; i < bytes.length; i++) {
        setByteVec(vec, i + 1, bytes[i]);
    }

    const diags = [
        'eval_julia_test_ps_create',
        'eval_julia_test_parse_only',
        'eval_julia_test_string_from_bytes',
        'eval_julia_test_parse_int',
        'eval_julia_test_substring',
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
    ];

    console.log("=== Diagnostic Results ===\n");
    for (const name of diags) {
        const fn = e[name];
        if (!fn) {
            console.log(`  ${name}: NOT EXPORTED`);
            continue;
        }
        try {
            const result = fn(vec);
            console.log(`  ${name}: ${result}`);
        } catch (err) {
            console.log(`  ${name}: ERROR — ${err.message}`);
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
