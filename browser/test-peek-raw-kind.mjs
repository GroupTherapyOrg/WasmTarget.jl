import { readFile } from "node:fs/promises";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

if (!isMainThread) {
    const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
    const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();
    const rt = new WasmTargetRuntime();
    const wasmBytes = await readFile(join(__dirname, workerData.wasmFile));
    const mod = await rt.load(wasmBytes, "test");
    const wasmStr = await rt.jsToWasmString(workerData.input);
    try {
        const result = mod.exports.peek_raw_kind(wasmStr);
        parentPort.postMessage({ status: "OK", result });
    } catch (e) {
        parentPort.postMessage({ status: "TRAP", error: (e.message || String(e)).substring(0, 500) });
    }
} else {
    async function runTest(input, wasmFile, timeoutMs = 10000) {
        return new Promise((resolve) => {
            const worker = new Worker(fileURLToPath(import.meta.url), {
                workerData: { input, wasmFile }
            });
            const timer = setTimeout(() => { worker.terminate(); resolve({ status: "HANG" }); }, timeoutMs);
            worker.on("message", (msg) => { clearTimeout(timer); resolve(msg); });
            worker.on("error", (err) => { clearTimeout(timer); resolve({ status: "ERROR", error: err.message }); });
        });
    }

    console.log("=== peek_raw_kind diagnostic ===\n");
    const tests = [
        ["1", 44, "Integer"],
        [" ", 1, "Whitespace"],
        ["1 + 1", 44, "Integer"],
    ];

    for (const [input, expected, name] of tests) {
        process.stdout.write(`  peek_raw_kind("${input}")... `);
        const result = await runTest(input, "peek_raw_kind.wasm", 10000);
        if (result.status === "HANG") {
            console.log("HUNG (10s)");
        } else if (result.status === "OK") {
            const match = result.result === expected ? `✓ ${name}` : `WRONG (expected ${expected}=${name}, got ${result.result})`;
            console.log(`${result.result} ${match}`);
        } else {
            console.log(`${result.status}: ${result.error}`);
        }
    }
}
