/**
 * PURE-316 Diagnostic: Trace parser hang by counting function calls.
 *
 * Strategy: Replace exported functions with counting wrappers, then
 * run parse_expr_string with a timeout. When it hangs, check which
 * functions were called most (= the infinite loop).
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";

const __dirname = dirname(fileURLToPath(import.meta.url));

if (!isMainThread) {
    // Worker: Run parse_expr_string and count calls
    const runtimeCode = await readFile(join(workerData.dir, "wasmtarget-runtime.js"), "utf-8");
    const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

    const rt = new WasmTargetRuntime();
    const wasmBytes = await readFile(join(workerData.dir, "parsestmt.wasm"));
    const parser = await rt.load(wasmBytes, "parsestmt");

    // Count calls to every exported function
    const callCounts = {};
    const originalExports = { ...parser.exports };

    // Track __lookahead_index specifically - it's called in loops
    for (const [name, fn] of Object.entries(originalExports)) {
        if (typeof fn === "function") {
            callCounts[name] = 0;
            parser.exports[name] = function(...args) {
                callCounts[name]++;
                // Report every 10000 calls
                if (callCounts[name] % 10000 === 0) {
                    parentPort.postMessage({ type: "progress", name, count: callCounts[name] });
                }
                return originalExports[name].apply(this, args);
            };
        }
    }

    // Create wasm string
    const wasmStr = await rt.jsToWasmString("1");

    // Call parse_expr_string (will hang)
    parentPort.postMessage({ type: "starting" });
    try {
        // Call original directly since we can't wrap the internal calls
        const result = originalExports.parse_expr_string(wasmStr);
        parentPort.postMessage({ type: "done", result: String(result), callCounts });
    } catch (e) {
        parentPort.postMessage({ type: "error", message: e.message, callCounts });
    }
} else {
    // Main thread: start worker with timeout
    console.log("=== PURE-316: Tracing Parser Hang ===\n");
    console.log("Strategy: Run parse_expr_string in worker, kill after 3s, analyze.");
    console.log("NOTE: Can only count EXTERNAL calls from JS. Internal wasm→wasm calls are invisible.\n");

    // Since wrapping exports only counts JS→wasm calls, not internal wasm→wasm calls,
    // let's instead use V8 profiling.
    console.log("Approach 2: Use --prof to identify hot functions.\n");

    // For now, just run with a short timeout and collect any info
    const worker = new Worker(new URL(import.meta.url), {
        workerData: { dir: __dirname }
    });

    let lastProgress = {};

    worker.on("message", (msg) => {
        if (msg.type === "starting") {
            console.log("Worker started parse_expr_string('1')...");
        } else if (msg.type === "progress") {
            lastProgress[msg.name] = msg.count;
            console.log(`  ${msg.name}: ${msg.count} calls`);
        } else if (msg.type === "done") {
            console.log(`DONE: ${msg.result}`);
            console.log("Call counts:", msg.callCounts);
            process.exit(0);
        } else if (msg.type === "error") {
            console.log(`ERROR: ${msg.message}`);
            console.log("Call counts:", msg.callCounts);
            process.exit(1);
        }
    });

    // Kill after 3 seconds
    setTimeout(() => {
        console.log("\nTIMEOUT: Worker killed after 3s.");
        console.log("Last progress:", lastProgress);
        console.log("\nConclusion: parse_expr_string hangs in internal wasm→wasm calls.");
        console.log("Cannot instrument internal calls from JS. Need different approach.");
        worker.terminate();
        process.exit(0);
    }, 3000);
}
