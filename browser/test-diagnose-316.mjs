/**
 * PURE-316 Diagnostic: Test parsestmt.wasm functions to find infinite loop root cause.
 * Uses worker threads for timeout on synchronous hangs.
 */
import { readFile } from "node:fs/promises";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

if (!isMainThread) {
    // Worker: load wasm and run the specified test
    const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
    const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();
    const rt = new WasmTargetRuntime();
    const wasmBytes = await readFile(join(__dirname, "parsestmt.wasm"));
    const parser = await rt.load(wasmBytes, "parsestmt");

    const { test, input } = workerData;

    try {
        if (test === "is_id_start") {
            const result = parser.exports.is_identifier_start_char(input);
            parentPort.postMessage({ status: "OK", result });
        } else if (test === "parse") {
            const wasmStr = await rt.jsToWasmString(input);
            const result = parser.exports.parse_expr_string(wasmStr);
            parentPort.postMessage({ status: "OK", result: String(result) });
        } else if (test === "list_exports") {
            const funcs = Object.keys(parser.exports).filter(k => typeof parser.exports[k] === "function").sort();
            parentPort.postMessage({ status: "OK", result: funcs });
        }
    } catch (e) {
        parentPort.postMessage({ status: "TRAP", error: (e.message || String(e)).substring(0, 500) });
    }
} else {
    async function runTest(test, input, timeoutMs = 10000) {
        return new Promise((resolve) => {
            const worker = new Worker(fileURLToPath(import.meta.url), {
                workerData: { test, input }
            });
            const timer = setTimeout(() => { worker.terminate(); resolve({ status: "HANG" }); }, timeoutMs);
            worker.on("message", (msg) => { clearTimeout(timer); resolve(msg); });
            worker.on("error", (err) => { clearTimeout(timer); resolve({ status: "ERROR", error: err.message }); });
        });
    }

    console.log("=== PURE-316 Diagnostic Tests ===\n");

    // Phase 1: Test is_identifier_start_char in parsestmt.wasm
    console.log("--- Phase 1: is_identifier_start_char ---");
    const idTests = [
        [120, "x", 1], [65, "A", 1], [95, "_", 1], [49, "1", 0], [43, "+", 0]
    ];
    for (const [code, name, expected] of idTests) {
        const r = await runTest("is_id_start", code, 5000);
        const ok = r.status === "OK" && r.result === expected;
        console.log(`  is_id_start('${name}') = ${r.status === "OK" ? r.result : r.status} ${ok ? "✓" : "✗"}`);
    }

    // Phase 2: Test parse_expr_string with simple inputs
    console.log("\n--- Phase 2: parse_expr_string (5s timeout) ---");
    const parseTests = ["1", "+", "1+1", "x", ""];
    for (const input of parseTests) {
        process.stdout.write(`  parse("${input}")... `);
        const r = await runTest("parse", input, 5000);
        if (r.status === "HANG") {
            console.log("HUNG (5s)");
        } else if (r.status === "OK") {
            console.log(`OK: ${r.result}`);
        } else {
            console.log(`${r.status}: ${r.error}`);
        }
    }

    // Phase 3: List parsestmt-relevant exports (look for internal functions we can probe)
    console.log("\n--- Phase 3: Exported Functions ---");
    const r = await runTest("list_exports", null, 5000);
    if (r.status === "OK") {
        console.log(`  ${r.result.length} functions exported`);
        // Show functions that might help diagnose
        const interesting = r.result.filter(n =>
            n.includes("parse") || n.includes("token") || n.includes("peek") ||
            n.includes("bump") || n.includes("lex") || n.includes("next") ||
            n.includes("buffer")
        );
        console.log("  Parser-related:");
        for (const f of interesting) {
            console.log(`    ${f}`);
        }
    }

    console.log("\nDone.");
}
