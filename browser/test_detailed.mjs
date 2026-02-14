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

    const input = '1+1';
    const s = await rt.jsToWasmString(input);
    try {
        const result = pa.exports.parse_expr_string(s);
        console.log(`PASS: returned ${typeof result}: ${result}`);
    } catch (e) {
        console.log(`FAIL: ${e.message}`);
        if (e.stack) {
            // Parse stack to find func numbers
            const lines = e.stack.split('\n');
            for (const line of lines.slice(0, 20)) {
                console.log(line);
            }
        }
    }
})();
