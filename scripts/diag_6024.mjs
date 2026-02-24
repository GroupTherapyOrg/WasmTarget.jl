// Diagnostic: trace the unreachable in eval_julia_to_bytes
import { readFile } from 'fs/promises';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

// String bridge module
const STRING_BRIDGE_BASE64 = "AGFzbQEAAAABJgZgAnx8AXxPAF5/AWABfwFjAWADYwF/fwBgAmMBfwF/YAFjAQF/AgwBBE1hdGgDcG93AAADBQQCAwQFBy8EB3N0cl9uZXcAAQxzdHJfc2V0Y2hhciEAAghzdHJfY2hhcgADB3N0cl9sZW4ABAosBAcAIAD7BwELDgAgACABQQFrIAL7DgELDAAgACABQQFr+wsBCwYAIAD7Dws=";

async function main() {
    const wasmPath = join(__dirname, '..', 'output', 'eval_julia.wasm');
    const wasmBytes = await readFile(wasmPath);

    // List all exports
    const imports = { Math: { pow: Math.pow } };
    const result = await WebAssembly.instantiate(wasmBytes, imports);
    const inst = result.instance;

    // Print all function exports
    const exports = Object.keys(inst.exports).filter(k => typeof inst.exports[k] === 'function');
    console.log(`Total function exports: ${exports.length}`);
    console.log("First 30 exports:", exports.slice(0, 30));

    // Check if there's a _string_to_bytes export
    const strExports = exports.filter(e => e.includes('string') || e.includes('String') || e.includes('bytes'));
    console.log("\nString-related exports:", strExports);

    // Check eval_julia exports
    const evalExports = exports.filter(e => e.includes('eval_julia'));
    console.log("\neval_julia exports:", evalExports);

    // Check if the module has its OWN str_new-like function
    const strNewExports = exports.filter(e => e.includes('new') || e.includes('create'));
    console.log("\nCreate/new exports (first 20):", strNewExports.slice(0, 20));

    // Try calling _string_to_bytes directly with different args
    if (inst.exports._string_to_bytes) {
        console.log("\n_string_to_bytes exists as export! Trying to call with bridge string...");
    }

    // The real question: what TYPE does eval_julia_to_bytes expect?
    // Let's try passing null to see what error we get
    try {
        console.log("\nTrying eval_julia_to_bytes(null)...");
        inst.exports.eval_julia_to_bytes(null);
    } catch (e) {
        console.log(`  Error: ${e.message}`);
    }

    // Try with a number
    try {
        console.log("\nTrying eval_julia_to_bytes(42)...");
        inst.exports.eval_julia_to_bytes(42);
    } catch (e) {
        console.log(`  Error: ${e.message}`);
    }

    // Load bridge and try with bridge string
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
    console.log(`\nBridge string type: ${typeof wasmStr}, value: ${wasmStr}`);

    try {
        console.log("\nTrying eval_julia_to_bytes(bridge_string)...");
        inst.exports.eval_julia_to_bytes(wasmStr);
    } catch (e) {
        console.log(`  Error at: ${e.stack?.split('\n')[1]}`);
    }

    // Can we find a String constructor in the module's exports?
    const constructors = exports.filter(e => e.startsWith('String') || e.includes('string_') || e.includes('_String'));
    console.log("\nString constructor exports:", constructors.slice(0, 20));

    // Look for ncodeunits or codeunit exports
    const codeunitExports = exports.filter(e => e.includes('codeunit') || e.includes('ncodeunits'));
    console.log("\ncodeunit exports:", codeunitExports);
}

main().catch(e => { console.error(e); process.exit(1); });
