/**
 * Test parsestmt.wasm using Worker threads with timeout.
 * WebAssembly runs synchronously, so we need a separate thread for timeout.
 */
import { readFile } from "node:fs/promises";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

if (!isMainThread) {
    // Worker: run parse_expr_string
    try {
        const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
        const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();
        const rt = new WasmTargetRuntime();
        const wasmBytes = await readFile(join(__dirname, "parsestmt.wasm"));
        const parser = await rt.load(wasmBytes, "parsestmt");

        const wasmStr = await rt.jsToWasmString(workerData.input);
        const result = parser.exports.parse_expr_string(wasmStr);
        parentPort.postMessage({ status: "OK", result: String(result) });
    } catch (e) {
        parentPort.postMessage({ status: "TRAP", error: (e.message || String(e)).substring(0, 500) });
    }
} else {
    // Main: spawn worker with timeout
    const input = process.argv[2] || "1";
    const timeoutMs = parseInt(process.argv[3] || "5000");

    console.log(`Testing parse_expr_string("${input}") with ${timeoutMs}ms timeout...`);

    const worker = new Worker(fileURLToPath(import.meta.url), {
        workerData: { input }
    });

    const timer = setTimeout(() => {
        console.log(`TIMEOUT: Parser hung for ${timeoutMs}ms`);
        worker.terminate();
        process.exit(2);
    }, timeoutMs);

    worker.on("message", (msg) => {
        clearTimeout(timer);
        console.log(`Result: ${msg.status}${msg.error ? ` — ${msg.error}` : ""}${msg.result ? ` — ${msg.result}` : ""}`);
        process.exit(msg.status === "OK" ? 0 : 1);
    });

    worker.on("error", (err) => {
        clearTimeout(timer);
        console.log(`Worker error: ${err.message}`);
        process.exit(1);
    });

    worker.on("exit", (code) => {
        clearTimeout(timer);
        if (code !== 0) {
            // Already handled
        }
    });
}
