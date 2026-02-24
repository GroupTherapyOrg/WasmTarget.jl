// Diagnostic: more detailed unreachable tracing for eval_julia_to_bytes
import { readFile } from 'fs/promises';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const STRING_BRIDGE_BASE64 = "AGFzbQEAAAABJgZgAnx8AXxPAF5/AWABfwFjAWADYwF/fwBgAmMBfwF/YAFjAQF/AgwBBE1hdGgDcG93AAADBQQCAwQFBy8EB3N0cl9uZXcAAQxzdHJfc2V0Y2hhciEAAghzdHJfY2hhcgADB3N0cl9sZW4ABAosBAcAIAD7BwELDgAgACABQQFrIAL7DgELDAAgACABQQFr+wsBCwYAIAD7Dws=";

async function main() {
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);
    const imports = { Math: { pow: Math.pow } };
    const result = await WebAssembly.instantiate(wasmBytes, imports);
    const inst = result.instance;

    const exports = Object.keys(inst.exports).filter(k => typeof inst.exports[k] === 'function');

    // Test: can we call _string_to_bytes?
    const stbExport = exports.find(e => e === '_string_to_bytes');
    console.log("_string_to_bytes export:", stbExport || "NOT FOUND");

    // Test: can we call ParseStream directly?
    const psExport = exports.find(e => e === 'ParseStream');
    console.log("ParseStream export:", psExport || "NOT FOUND");

    // Load bridge and create string
    const bridgeBytes = Buffer.from(STRING_BRIDGE_BASE64, "base64");
    const bridgeResult = await WebAssembly.instantiate(bridgeBytes, imports);
    const bridge = bridgeResult.instance.exports;

    function jsToWasmString(str) {
        const codepoints = [...str];
        const wasmStr = bridge.str_new(codepoints.length);
        for (let i = 0; i < codepoints.length; i++) {
            bridge["str_setchar!"](wasmStr, i + 1, codepoints[i].codePointAt(0));
        }
        return wasmStr;
    }

    const wasmStr = jsToWasmString("1+1");
    console.log(`\nBridge string: ${typeof wasmStr} value=${wasmStr}`);

    // Test 1: Try _string_to_bytes with bridge string
    if (inst.exports._string_to_bytes) {
        try {
            console.log("\nCalling _string_to_bytes(bridge_string)...");
            const result = inst.exports._string_to_bytes(wasmStr);
            console.log(`  Result: ${result} (type: ${typeof result})`);
        } catch (e) {
            console.log(`  ERROR: ${e.message}`);
            const stack = e.stack?.split('\n').slice(0, 5).map(l => l.trim());
            console.log(`  Stack:`, stack);
        }
    }

    // Test 2: Try ParseStream with bridge string
    if (inst.exports.ParseStream) {
        try {
            console.log("\nCalling ParseStream(bridge_string)...");
            const result = inst.exports.ParseStream(wasmStr);
            console.log(`  Result: ${result} (type: ${typeof result})`);
        } catch (e) {
            console.log(`  ERROR: ${e.message}`);
            const stack = e.stack?.split('\n').slice(0, 5).map(l => l.trim());
            console.log(`  Stack:`, stack);
        }
    }

    // Test 3: Full call
    try {
        console.log("\nCalling eval_julia_to_bytes(bridge_string)...");
        inst.exports.eval_julia_to_bytes(wasmStr);
    } catch (e) {
        console.log(`  ERROR: ${e.message}`);
        const stack = e.stack?.split('\n').slice(0, 8).map(l => l.trim());
        console.log(`  Stack:`, stack);
    }

    // Test 4: What about passing an externref that IS from the main module?
    // Try to get a string from one of the module's own functions
    // Check for ncodeunits or codeunit
    const ncu = exports.find(e => e === 'ncodeunits');
    const cu = exports.find(e => e === 'codeunit');
    console.log("\nncodeunits export:", ncu || "NOT FOUND");
    console.log("codeunit export:", cu || "NOT FOUND");

    // Check for any function that returns a String we could use
    console.log("\nAll exports (showing all):");
    for (let i = 0; i < exports.length; i++) {
        if (exports[i].length < 30) {
            // Try calling with no args to see its signature
        }
    }
    console.log("  Total:", exports.length);
    console.log("  Looking for String-producing functions...");
    const candidates = exports.filter(e =>
        e.includes('string') || e.includes('String') ||
        e === 'repr' || e === 'sprint' || e === 'Symbol'
    );
    console.log("  Candidates:", candidates);
}

main().catch(e => { console.error(e); process.exit(1); });
