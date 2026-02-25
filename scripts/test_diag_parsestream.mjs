// PURE-6023 Agent 43: Test diagnostic ParseStream stages
import { readFileSync } from 'fs';

async function main() {
    const bytes = readFileSync('/tmp/diag_parsestream.wasm');
    console.log(`Module: ${bytes.length} bytes (${(bytes.length/1024).toFixed(1)} KB)`);

    const { instance } = await WebAssembly.instantiate(bytes, {
        Math: { pow: Math.pow }
    });
    const ex = instance.exports;
    const funcExports = Object.keys(ex).filter(k => typeof ex[k] === 'function');
    console.log(`INSTANTIATE SUCCESS (${funcExports.length} func exports)`);

    // Helper: create WasmGC byte vec from JS string
    function jsToWasmBytes(str) {
        const enc = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](enc.length);
        for (let i = 0; i < enc.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, enc[i]);
        }
        return vec;
    }

    const vec = jsToWasmBytes("1+1");

    // Stage 0: length
    try {
        const r = Number(ex['diag_len'](vec));
        console.log(`Stage 0 (length): ${r} — ${r === 3 ? 'CORRECT' : 'WRONG'}`);
    } catch (e) {
        console.log(`Stage 0 (length): TRAPPED — ${e.message}`);
    }

    // Stage 1: ParseStream create
    try {
        const r = Number(ex['diag_ps_create'](vec));
        console.log(`Stage 1 (ParseStream): ${r} — ${r === 1 ? 'EXECUTES' : 'WRONG'}`);
    } catch (e) {
        console.log(`Stage 1 (ParseStream): TRAPPED — ${e.message}`);
    }

    // Stage 2: ParseStream + parse
    try {
        const r = Number(ex['diag_ps_parse'](vec));
        console.log(`Stage 2 (parse!): ${r} — ${r === 2 ? 'EXECUTES' : 'WRONG'}`);
    } catch (e) {
        console.log(`Stage 2 (parse!): TRAPPED — ${e.message}`);
    }

    // Stage 3: cursor
    try {
        const r = Number(ex['diag_ps_cursor'](vec));
        console.log(`Stage 3 (cursor): ${r} — ${r === 3 ? 'EXECUTES' : 'WRONG'}`);
    } catch (e) {
        console.log(`Stage 3 (cursor): TRAPPED — ${e.message}`);
    }

    // Stage 4: full eval
    const testCases = [["1+1", 2], ["2+3", 5], ["9-3", 6], ["6*7", 42]];
    console.log("\n--- Full _wasm_eval_arith ---");
    let pass = 0;
    for (const [expr, expected] of testCases) {
        const v = jsToWasmBytes(expr);
        try {
            const result = Number(ex['_wasm_eval_arith'](v));
            const ok = result === expected;
            console.log(`  eval("${expr}") = ${result} — ${ok ? 'CORRECT ✓' : `WRONG (expected ${expected})`}`);
            if (ok) pass++;
        } catch (e) {
            console.log(`  eval("${expr}") TRAPPED: ${e.message}`);
        }
    }
    console.log(`\n=== RESULT: ${pass}/${testCases.length} CORRECT ===`);
}

main().catch(e => { console.error(e); process.exit(1); });
