// PURE-6023 Agent 43: Get detailed trap location
import { readFileSync } from 'fs';

async function main() {
    const bytes = readFileSync('/tmp/diag_parse_stages.wasm');
    const { instance } = await WebAssembly.instantiate(bytes, {
        Math: { pow: Math.pow }
    });
    const ex = instance.exports;

    function jsToWasmBytes(str) {
        const enc = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](enc.length);
        for (let i = 0; i < enc.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, enc[i]);
        }
        return vec;
    }

    const vec = jsToWasmBytes("1+1");

    // Try to get trap details with stack trace
    try {
        ex['diag_d_parse'](vec);
    } catch (e) {
        console.log("Error:", e.message);
        console.log("Stack trace:");
        console.log(e.stack);
    }
}

main().catch(e => { console.error(e); process.exit(1); });
