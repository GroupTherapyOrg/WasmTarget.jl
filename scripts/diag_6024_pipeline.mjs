// PURE-6024 Pipeline diagnostic — test eval_julia_to_bytes_vec step by step
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    const imports = { Math: { pow: Math.pow } };

    console.log("Loading module...");
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    const e = instance.exports;
    console.log("Module loaded.\n");

    // Create input: "1+1" as byte vector
    const str = "1+1";
    const bytes = new TextEncoder().encode(str);
    console.log(`Creating byte vec for "${str}" (${bytes.length} bytes: ${[...bytes].join(', ')})...`);
    const vec = e['make_byte_vec'](bytes.length);
    for (let i = 0; i < bytes.length; i++) {
        e['set_byte_vec!'](vec, i + 1, bytes[i]);
    }
    const len = e['eval_julia_result_length'](vec);
    console.log(`Byte vec created, length: ${len}`);

    // Verify bytes round-trip
    for (let i = 1; i <= len; i++) {
        const b = e['eval_julia_result_byte'](vec, i);
        console.log(`  byte[${i}] = ${b} (${String.fromCharCode(b)})`);
    }

    // Call eval_julia_to_bytes_vec
    console.log(`\nCalling eval_julia_to_bytes_vec...`);
    try {
        const result = e['eval_julia_to_bytes_vec'](vec);
        console.log("SUCCESS! Got result.");

        // Extract result bytes
        const resultLen = e['eval_julia_result_length'](result);
        console.log(`Result byte length: ${resultLen}`);

        if (resultLen > 0) {
            const resultBytes = new Uint8Array(resultLen);
            for (let i = 1; i <= resultLen; i++) {
                resultBytes[i - 1] = e['eval_julia_result_byte'](result, i);
            }
            const magic = resultBytes[0] === 0x00 && resultBytes[1] === 0x61 &&
                          resultBytes[2] === 0x73 && resultBytes[3] === 0x6d;
            console.log(`WASM magic: ${magic}`);
            console.log(`First 16 bytes: ${[...resultBytes.slice(0, 16)].map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ')}`);

            if (magic) {
                // Try instantiate inner module
                const inner = await WebAssembly.instantiate(resultBytes.buffer, imports);
                const innerExports = Object.keys(inner.instance.exports);
                console.log(`Inner module exports: ${innerExports.join(', ')}`);

                const fn = inner.instance.exports['+'];
                if (fn) {
                    const r = fn(1n, 1n);
                    console.log(`+(1, 1) = ${r} (expected 2) → ${r === 2n ? 'CORRECT' : 'WRONG'}`);
                }
            }
        }
    } catch (err) {
        console.error(`FAIL: ${err.message}`);
        if (err.stack) {
            const lines = err.stack.split('\n').slice(0, 8);
            for (const line of lines) console.log(`  ${line}`);
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
