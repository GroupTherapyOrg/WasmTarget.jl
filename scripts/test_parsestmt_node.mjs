// PURE-324 attempt 8: Test parsestmt.wasm with detailed error info
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const browserDir = join(__dirname, '..', 'browser');

const rtCode = readFileSync(join(browserDir, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rtCode + '\nreturn WasmTargetRuntime;')();

async function test() {
    const rt = new WRT();
    const wasmBytes = readFileSync(join(browserDir, 'parsestmt.wasm'));

    console.log(`Loading parsestmt.wasm (${wasmBytes.length} bytes)...`);
    const mod = await rt.load(wasmBytes, 'parsestmt');

    // List exported functions
    const exports = Object.keys(mod.exports).filter(k => typeof mod.exports[k] === 'function');
    console.log(`Exports: ${exports.join(', ')}`);

    // Try with simple input "1"
    const s = await rt.jsToWasmString("1");
    console.log(`\nTesting parse_expr_string("1")...`);
    try {
        const result = mod.exports.parse_expr_string(s);
        console.log(`PASS: result = ${result}`);
    } catch(e) {
        console.log(`FAIL: ${e.message}`);
        if (e.stack) {
            // Extract wasm function info from stack trace
            const lines = e.stack.split('\n');
            for (const line of lines) {
                if (line.includes('wasm')) {
                    console.log(`  ${line.trim()}`);
                }
            }
        }
    }
}

test().catch(e => console.error(e));
