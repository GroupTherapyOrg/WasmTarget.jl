// Test _wasm_parse_arith with multiple expressions
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== _wasm_parse_arith CORRECT Test ===\n");
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const ex = instance.exports;

    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    // Ground truth from native Julia:
    //   "1+1" => 43001001 (op=43, left=1, right=1)
    //   "2+3" => 43002003 (op=43, left=2, right=3)
    //   "6*7" => 42006007 (op=42, left=6, right=7)
    //   "9-3" => 45009003 (op=45, left=9, right=3)
    const tests = [
        { expr: "1+1", expected: 43001001 },
        { expr: "2+3", expected: 43002003 },
        { expr: "6*7", expected: 42006007 },
        { expr: "9-3", expected: 45009003 },
    ];

    let allCorrect = true;
    for (const { expr, expected } of tests) {
        const vec = jsToWasmBytes(expr);
        try {
            const result = ex['eval_julia_test_parse_arith'](vec);
            const correct = result === expected;
            const op = String.fromCharCode(Math.floor(result / 1000000));
            const left = Math.floor((result / 1000) % 1000);
            const right = result % 1000;
            console.log(`  "${expr}" => ${result} (op='${op}' left=${left} right=${right}) — expected ${expected} — ${correct ? "CORRECT" : "WRONG"}`);
            if (!correct) allCorrect = false;
        } catch (e) {
            console.log(`  "${expr}" => ERROR: ${e.message}`);
            allCorrect = false;
        }
    }

    console.log(`\n${allCorrect ? "ALL 4 CORRECT — Stage 1 parse WORKS in WASM!" : "SOME TESTS FAILED"}`);
}

main().catch(e => { console.error(e); process.exit(1); });
