import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const rc = fs.readFileSync(path.join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

(async () => {
    const rt = new WRT();
    const w = fs.readFileSync(path.join(__dirname, 'parsestmt.wasm'));
    const pa = await rt.load(w, 'parsestmt');

    // Test various inputs with increasing complexity
    const tests = [
        '1',      // leaf: Integer
        '42',     // leaf: Integer (multi-digit)
        'x',      // leaf: Identifier -> Symbol
        '1+1',    // call: 3 children
        '-1',     // call: 2 children (unary minus)
        '(1)',    // parens: 1 child
    ];

    for (const input of tests) {
        const s = await rt.jsToWasmString(input);
        try {
            const result = pa.exports.parse_expr_string(s);
            console.log(`"${input}" -> EXECUTES (${typeof result}: ${result})`);
        } catch (e) {
            // Extract function number from stack trace
            const match = e.stack?.match(/wasm-function\[(\d+)\]:0x([0-9a-f]+)/);
            const funcInfo = match ? ` func[${match[1]}] @0x${match[2]}` : '';
            console.log(`"${input}" -> FAIL: ${e.message}${funcInfo}`);
        }
    }
})();
