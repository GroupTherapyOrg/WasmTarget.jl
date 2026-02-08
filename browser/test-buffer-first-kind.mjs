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
        const result = mod.exports[workerData.funcName](wasmStr);
        parentPort.postMessage({ status: "OK", result });
    } catch (e) {
        parentPort.postMessage({ status: "TRAP", error: (e.message || String(e)).substring(0, 500) });
    }
} else {
    async function runTest(wasmFile, funcName, input, timeoutMs = 10000) {
        return new Promise((resolve) => {
            const worker = new Worker(fileURLToPath(import.meta.url), {
                workerData: { wasmFile, funcName, input }
            });
            const timer = setTimeout(() => { worker.terminate(); resolve({ status: "HANG" }); }, timeoutMs);
            worker.on("message", (msg) => { clearTimeout(timer); resolve(msg); });
            worker.on("error", (err) => { clearTimeout(timer); resolve({ status: "ERROR", error: err.message }); });
        });
    }

    console.log("=== Buffer First Kind Diagnostic ===\n");
    const tests = [
        ["1", 44, "Integer"],
        [" ", 1, "Whitespace"],
        ["+", 535, "Plus"],
    ];

    for (const [input, expected, name] of tests) {
        process.stdout.write(`  buffer_first_kind("${input}")... `);
        const result = await runTest("buffer_first_kind.wasm", "buffer_first_kind", input, 10000);
        if (result.status === "HANG") {
            console.log("HUNG");
        } else if (result.status === "OK") {
            const ok = result.result === expected;
            console.log(`${result.result} ${ok ? `✓ ${name}` : `✗ WRONG (expected ${expected}=${name})`}`);
        } else {
            console.log(`${result.status}: ${result.error}`);
        }
    }
}
