/**
 * PURE-316: Profile parser hang by intercepting peek_count.
 *
 * Strategy: Use a Proxy on the wasm instance to intercept
 * table/memory access and track call patterns.
 *
 * Better strategy: Use --experimental-wasm-compilation-hints
 * or simply add console.log-based instrumentation.
 *
 * Actual strategy: Run with --prof flag and analyze v8.log
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";

const __dirname = dirname(fileURLToPath(import.meta.url));

if (!isMainThread) {
    // Worker: instrument and run
    const runtimeCode = await readFile(join(workerData.dir, "wasmtarget-runtime.js"), "utf-8");
    const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

    const rt = new WasmTargetRuntime();
    const wasmBytes = await readFile(join(workerData.dir, "parsestmt.wasm"));
    const parser = await rt.load(wasmBytes, "parsestmt");

    // Try to check specific exported functions that might loop
    // In parsestmt.wasm, all funcs are exported. Let's wrap the key ones
    // and count calls.
    const exports = parser.exports;
    const callLog = [];
    let callCount = 0;
    const MAX_LOG = 200;

    // Wrap ALL exported functions to count calls
    const counts = {};
    const originals = {};
    for (const [name, fn] of Object.entries(exports)) {
        if (typeof fn === "function") {
            originals[name] = fn;
            counts[name] = 0;
            exports[name] = function(...args) {
                counts[name]++;
                callCount++;
                if (callCount <= MAX_LOG) {
                    callLog.push(name);
                }
                if (callCount % 50000 === 0) {
                    // Report top callers
                    const top = Object.entries(counts)
                        .sort((a,b) => b[1] - a[1])
                        .slice(0, 10);
                    parentPort.postMessage({
                        type: "tick",
                        total: callCount,
                        top: top.map(([n,c]) => `${n}:${c}`)
                    });
                }
                return originals[name].apply(this, args);
            };
        }
    }

    const wasmStr = await rt.jsToWasmString("1");
    parentPort.postMessage({ type: "starting" });

    try {
        // Call the ORIGINAL parse_expr_string directly (not wrapped)
        // because internal wasm->wasm calls don't go through JS wrappers
        const result = originals.parse_expr_string(wasmStr);
        parentPort.postMessage({ type: "done", result: String(result), callLog, counts });
    } catch(e) {
        parentPort.postMessage({ type: "error", message: e.message, callLog, counts });
    }
} else {
    console.log("=== PURE-316: Profile Parser Hang ===\n");
    console.log("NOTE: Only JS->wasm calls are counted. Internal wasm->wasm calls are invisible.\n");

    const worker = new Worker(new URL(import.meta.url), {
        workerData: { dir: __dirname }
    });

    worker.on("message", (msg) => {
        if (msg.type === "starting") {
            console.log("Starting parse_expr_string('1')...");
        } else if (msg.type === "tick") {
            console.log(`  Calls: ${msg.total} | Top: ${msg.top.join(", ")}`);
        } else if (msg.type === "done") {
            console.log(`DONE: ${msg.result}`);
            console.log("First calls:", msg.callLog.slice(0, 30));
            console.log("Counts:", JSON.stringify(msg.counts));
        } else if (msg.type === "error") {
            console.log(`ERROR: ${msg.message}`);
            console.log("First calls:", msg.callLog?.slice(0, 30));
            // Show non-zero counts
            if (msg.counts) {
                const nonzero = Object.entries(msg.counts).filter(([_,c]) => c > 0);
                console.log("Non-zero counts:", nonzero.length ? JSON.stringify(Object.fromEntries(nonzero)) : "NONE");
            }
        }
    });

    setTimeout(() => {
        console.log("\nTIMEOUT (3s): Worker hung.");
        console.log("Since JS->wasm wrapping doesn't intercept internal calls,");
        console.log("the hang is entirely within wasm (wasm->wasm calls only).");
        console.log("\nConclusion: Need to analyze WAT to find the infinite loop.");
        worker.terminate();
        process.exit(0);
    }, 3000);
}
