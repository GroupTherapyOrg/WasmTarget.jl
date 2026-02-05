import { readFile } from "node:fs/promises";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

if (!isMainThread) {
    const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
    const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();
    const rt = new WasmTargetRuntime();
    const wasmBytes = await readFile(join(__dirname, "get_first_kind.wasm"));
    const mod = await rt.load(wasmBytes, "get_first_kind");
    const wasmStr = await rt.jsToWasmString(workerData.input);
    try {
        const result = mod.exports.get_first_kind(wasmStr);
        parentPort.postMessage({ status: "OK", result });
    } catch (e) {
        parentPort.postMessage({ status: "TRAP", error: (e.message || String(e)).substring(0, 500) });
    }
} else {
    async function runTest(input, timeoutMs = 10000) {
        return new Promise((resolve) => {
            const worker = new Worker(fileURLToPath(import.meta.url), {
                workerData: { input }
            });
            const timer = setTimeout(() => { worker.terminate(); resolve({ status: "HANG" }); }, timeoutMs);
            worker.on("message", (msg) => { clearTimeout(timer); resolve(msg); });
            worker.on("error", (err) => { clearTimeout(timer); resolve({ status: "ERROR", error: err.message }); });
        });
    }

    console.log("--- get_first_kind Tests (ParseStream + peek) ---\n");

    // Native values: "1" → 44 (Integer), "x" → 3 (Identifier)
    const tests = [
        ["1", 44],   // K"Integer"
        ["x", 3],    // K"Identifier"
        ["+", null],  // K"+"
        ["(", null],  // K"("
    ];

    for (const [input, expected] of tests) {
        process.stdout.write(`  get_first_kind("${input}")... `);
        const result = await runTest(input, 10000);
        if (result.status === "HANG") {
            console.log("HUNG (10s)");
        } else if (result.status === "OK") {
            const match = expected !== null ? (result.result === expected ? " ✓" : ` expected ${expected}`) : "";
            console.log(`${result.result}${match}`);
        } else {
            console.log(`${result.status}: ${result.error}`);
        }
    }
}
