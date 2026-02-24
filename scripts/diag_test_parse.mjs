// Test ParseStream in isolation
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    const wasmPath = join(__dirname, '..', 'output', 'test_parse.wasm');
    const wasmBytes = await readFile(wasmPath);
    const imports = { Math: { pow: Math.pow } };

    console.log("Loading test_parse.wasm...");
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const e = instance.exports;

    const funcExports = Object.keys(e).filter(k => typeof e[k] === 'function');
    console.log(`Exports: ${funcExports.join(', ')}`);

    // Create "1+1" bytes
    const vec = e['make_byte_vec'](3);
    e['set_byte_vec!'](vec, 1, 49);  // '1'
    e['set_byte_vec!'](vec, 2, 43);  // '+'
    e['set_byte_vec!'](vec, 3, 49);  // '1'
    console.log("Created byte vec for '1+1'");

    // Call test_parse
    console.log("Calling test_parse...");
    try {
        const result = e['test_parse'](vec);
        console.log(`test_parse returned: ${result} → PASS`);
    } catch (err) {
        console.error(`test_parse FAILED: ${err.message}`);
        if (err.stack) {
            const lines = err.stack.split('\n').slice(0, 8);
            for (const line of lines) console.log(`  ${line}`);
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
