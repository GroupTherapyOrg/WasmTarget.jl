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

    console.log("=== ParseStream State Diagnostic ===\n");

    const tests = [
        { wasmFile: "ps_lookahead_index.wasm", funcName: "ps_lookahead_index", desc: "ParseStream.lookahead_index" },
        { wasmFile: "ps_lookahead_count.wasm", funcName: "ps_lookahead_count", desc: "ParseStream.lookahead length" },
    ];

    for (const { wasmFile, funcName, desc } of tests) {
        process.stdout.write(`  ${desc}("1")... `);
        const result = await runTest(wasmFile, funcName, "1", 10000);
        if (result.status === "HANG") {
            console.log("HUNG");
        } else if (result.status === "OK") {
            console.log(`${result.result}`);
        } else {
            console.log(`${result.status}: ${result.error}`);
        }
    }
}
