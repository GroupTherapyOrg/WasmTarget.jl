// PURE-6027: Debug fresh arith module — identify which function traps
import { readFileSync } from 'fs';

async function main() {
    const bytes = readFileSync('/tmp/eval_arith_fresh.wasm');
    console.log(`Module: ${bytes.length} bytes`);

    const { instance } = await WebAssembly.instantiate(bytes, {
        Math: { pow: Math.pow }
    });
    const ex = instance.exports;
    const funcExports = Object.keys(ex).filter(k => typeof ex[k] === 'function');
    console.log(`${funcExports.length} func exports`);

    // List all exports
    console.log("\nExports:", funcExports.slice(0, 20).join(', '));

    // Test 1: make_byte_vec
    console.log("\n--- Step-by-step testing ---");
    try {
        const vec = ex['make_byte_vec'](3);
        console.log(`1. make_byte_vec(3) — OK (returned object)`);
    } catch (e) {
        console.log(`1. make_byte_vec TRAPPED: ${e.message}`);
        return;
    }

    // Test 2: set_byte_vec!
    try {
        const vec = ex['make_byte_vec'](3);
        ex['set_byte_vec!'](vec, 1, 49); // '1'
        ex['set_byte_vec!'](vec, 2, 43); // '+'
        ex['set_byte_vec!'](vec, 3, 49); // '1'
        console.log(`2. set_byte_vec! — OK`);
    } catch (e) {
        console.log(`2. set_byte_vec! TRAPPED: ${e.message}`);
        return;
    }

    // Test 3: ParseStream constructor
    if (ex['ParseStream']) {
        try {
            const vec = ex['make_byte_vec'](3);
            ex['set_byte_vec!'](vec, 1, 49);
            ex['set_byte_vec!'](vec, 2, 43);
            ex['set_byte_vec!'](vec, 3, 49);
            const ps = ex['ParseStream'](vec);
            console.log(`3. ParseStream() — OK (returned object)`);
        } catch (e) {
            console.log(`3. ParseStream TRAPPED: ${e.message}`);
        }
    } else {
        console.log('3. ParseStream not exported');
    }

    // Test 4: _wasm_parse_arith (if ParseStream works, we can test this separately)
    if (ex['_wasm_parse_arith']) {
        console.log('4. _wasm_parse_arith is exported');
    }

    // Test 5: Full eval
    try {
        const vec = ex['make_byte_vec'](3);
        ex['set_byte_vec!'](vec, 1, 49);
        ex['set_byte_vec!'](vec, 2, 43);
        ex['set_byte_vec!'](vec, 3, 49);
        const result = Number(ex['_wasm_eval_arith'](vec));
        console.log(`5. _wasm_eval_arith("1+1") = ${result}`);
    } catch (e) {
        console.log(`5. _wasm_eval_arith TRAPPED: ${e.message}`);
    }
}

main().catch(e => { console.error(e); process.exit(1); });
