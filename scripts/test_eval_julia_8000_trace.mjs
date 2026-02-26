// PURE-8000: Trace exact trap location in runtime compile function
// Uses --experimental-wasm-stack-switching for detailed stack traces
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    console.log("=== PURE-8000: Trap trace for _wasm_runtime_compile_plus_i64 ===\n");

    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    console.log(`File size: ${wasmBytes.length} bytes`);

    const imports = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const ex = instance.exports;

    // Helper: create WasmGC byte vec from JS string
    function jsToWasmBytes(str) {
        const bytes = new TextEncoder().encode(str);
        const vec = ex['make_byte_vec'](bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            ex['set_byte_vec!'](vec, i + 1, bytes[i]);
        }
        return vec;
    }

    // Test each stage3 diagnostic to find exact trap point
    console.log("--- Stage 3 sub-diagnostics ---");
    const tests = [
        ['_diag_stage3a_world', 'World age capture'],
        ['_diag_stage3b_sig', 'Signature construction'],
        ['_diag_stage3c_interp', 'WasmInterpreter construction'],
        ['_diag_stage3d_findall', 'Core.Compiler.findall'],
        ['_diag_stage3e_typeinf', 'typeinf_frame'],
    ];

    for (const [fn, desc] of tests) {
        const vec = jsToWasmBytes('1+1');
        try {
            const result = ex[fn](vec);
            console.log(`  ${fn} (${desc}) = ${result} — OK`);
        } catch (e) {
            console.log(`  ${fn} (${desc}) TRAP: ${e.message}`);
            // Try to extract the full stack
            if (e.stack) {
                const lines = e.stack.split('\n').slice(0, 10);
                for (const line of lines) {
                    if (line.includes('wasm-function')) {
                        console.log(`    ${line.trim()}`);
                    }
                }
            }
        }
    }
    console.log();

    // Direct call to runtime compile with full stack trace
    console.log("--- _wasm_runtime_compile_plus_i64 trap trace ---");
    try {
        const result = ex['_wasm_runtime_compile_plus_i64']();
        console.log(`  SUCCESS: ${result}`);
    } catch (e) {
        console.log(`  TRAP: ${e.message}`);
        if (e.stack) {
            const lines = e.stack.split('\n');
            console.log(`  Full stack (${lines.length} frames):`);
            for (const line of lines) {
                if (line.includes('wasm-function')) {
                    // Extract function index from wasm-function[N]
                    const m = line.match(/wasm-function\[(\d+)\]/);
                    const offset = line.match(/:0x([0-9a-f]+)/);
                    if (m) {
                        console.log(`    func[${m[1]}] offset=${offset ? '0x' + offset[1] : 'unknown'}`);
                    }
                }
            }
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
