// PURE-5001: Test stage_tests.wasm — does parsestmt EXECUTE?
import fs from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const wasmPath = join(__dirname, 'stage_tests.wasm');

if (!fs.existsSync(wasmPath)) {
    console.error(`ERROR: ${wasmPath} not found`);
    process.exit(1);
}

const bytes = fs.readFileSync(wasmPath);
console.log(`Loaded stage_tests.wasm: ${bytes.length} bytes (${(bytes.length/1024).toFixed(0)} KB)`);

async function run() {
    const imports = { Math: { pow: Math.pow } };
    let instance;
    try {
        const result = await WebAssembly.instantiate(bytes, imports);
        instance = result.instance;
        console.log("Module instantiated OK");
    } catch (err) {
        console.log(`INSTANTIATION FAILED: ${err.message}`);
        process.exit(1);
    }

    const e = instance.exports;

    // List test exports
    const testExports = Object.keys(e).filter(k => k.startsWith('test_'));
    console.log(`Test exports: ${testExports.join(', ')}\n`);

    // Test each
    for (const name of testExports) {
        process.stdout.write(`  ${name}(): `);
        try {
            const result = e[name]();
            console.log(`EXECUTES — returned ${typeof result}: ${result}`);
        } catch (err) {
            console.log(`TRAP — ${err.message}`);
            // Try to get more details
            if (err.stack) {
                const lines = err.stack.split('\n').slice(0, 5);
                for (const line of lines) {
                    console.log(`    ${line}`);
                }
            }
        }
    }
}

run().catch(err => {
    console.error(`Fatal: ${err.message}`);
    process.exit(1);
});
