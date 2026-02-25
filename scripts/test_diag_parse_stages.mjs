// PURE-6023 Agent 43: Test granular parse stages
import { readFileSync } from 'fs';

async function main() {
    const bytes = readFileSync('/tmp/diag_parse_stages.wasm');
    console.log(`Module: ${bytes.length} bytes (${(bytes.length/1024).toFixed(1)} KB)`);

    const { instance } = await WebAssembly.instantiate(bytes, {
        Math: { pow: Math.pow }
    });
    const ex = instance.exports;
    const funcExports = Object.keys(ex).filter(k => typeof ex[k] === 'function');
    console.log(`INSTANTIATE SUCCESS (${funcExports.length} func exports)`);

    // Helper
    function jsToWasmBytes(str) {
        const enc = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](enc.length);
        for (let i = 0; i < enc.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, enc[i]);
        }
        return vec;
    }

    const vec = jsToWasmBytes("1+1");

    const stages = [
        ['diag_a_create_ps', 'A: ParseStream create', 1],
        ['diag_b_textbuf', 'B: textbuf access', 3],      // length of "1+1" = 3
        ['diag_c_first_byte', 'C: first byte', 49],       // '1' = 49
        ['diag_d_parse', 'D: parse!', 2],
        ['diag_e_cursor', 'E: cursor', 3],
    ];

    for (const [fname, label, expected] of stages) {
        try {
            const r = Number(ex[fname](vec));
            const ok = r === expected;
            console.log(`${label}: ${r} — ${ok ? 'CORRECT ✓' : `got ${r}, expected ${expected}`}`);
        } catch (e) {
            console.log(`${label}: TRAPPED — ${e.message}`);
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
