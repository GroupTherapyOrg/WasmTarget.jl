/**
 * Test parsestmt.wasm with timeout to detect hang.
 * Also test with simple/empty inputs to narrow down the issue.
 */
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WasmTargetRuntime();

// Load parsestmt.wasm
const wasmBytes = await readFile(join(__dirname, "parsestmt.wasm"));
const parser = await rt.load(wasmBytes, "parsestmt");
console.log("parsestmt.wasm loaded:", Object.keys(parser.exports).length, "exports");

// Test: Call with a timeout wrapper
async function testWithTimeout(input, timeoutMs = 3000) {
    const wasmStr = await rt.jsToWasmString(input);

    return new Promise((resolve) => {
        const timer = setTimeout(() => {
            resolve({ status: "HANG", input });
        }, timeoutMs);

        // Run in a try/catch
        try {
            const result = parser.exports.parse_expr_string(wasmStr);
            clearTimeout(timer);
            resolve({ status: "OK", input, result });
        } catch (e) {
            clearTimeout(timer);
            const msg = e.message || String(e);
            resolve({ status: "TRAP", input, error: msg.substring(0, 200) });
        }
    });
}

// Test various inputs
const inputs = ["1", "x", "1+1", ""];
for (const input of inputs) {
    console.log(`\nTesting: "${input}" ...`);
    const result = await testWithTimeout(input, 5000);
    console.log(`  Result: ${result.status}${result.error ? ` — ${result.error}` : ""}${result.result !== undefined ? ` — returned: ${result.result}` : ""}`);

    if (result.status === "HANG") {
        console.log("  Parser hung. Aborting remaining tests.");
        process.exit(1);
    }
}

console.log("\nAll tests complete.");
process.exit(0);
