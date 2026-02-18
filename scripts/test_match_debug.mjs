// Debug method matching wrapper errors
import fs from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const wasmPath = path.join(__dirname, 'typeinf_4153.wasm');
const bytes = fs.readFileSync(wasmPath);

async function run() {
    const importObject = { Math: { pow: Math.pow } };
    const wasmModule = await WebAssembly.instantiate(bytes, importObject);
    const exports = wasmModule.instance.exports;

    console.log("Module loaded OK");

    // List all test exports
    const testExports = Object.keys(exports).filter(k => k.startsWith('test_'));
    console.log("Test exports:", testExports.join(", "));

    // Try method matching wrappers with verbose error
    for (const name of ['test_match_1', 'test_match_2', 'test_match_3', 'test_match_4', 'test_match_5']) {
        try {
            const result = exports[name]();
            console.log(`${name}: ${result}`);
        } catch (e) {
            console.log(`${name}: ERROR — ${e.message}`);
            // Try to get the function index from the stack trace
            if (e.stack) {
                const match = e.stack.match(/wasm-function\[(\d+)\]/);
                if (match) {
                    console.log(`  Trap in wasm-function[${match[1]}]`);
                }
            }
        }
    }
}

run();
