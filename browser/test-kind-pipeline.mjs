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
        const funcName = workerData.funcName;
        const result = mod.exports[funcName](wasmStr);
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

    console.log("=== Token Kind Pipeline Diagnostic ===\n");

    const tests = [
        { wasmFile: "lex_raw_kind_from_stream.wasm", funcName: "lex_raw_kind_from_stream", desc: "Step 1: Lexer.next_token → raw.kind" },
        { wasmFile: "construct_and_read_head.wasm", funcName: "construct_and_read_head", desc: "Step 2: SyntaxHead(kind, 0) → head.kind" },
        { wasmFile: "construct_and_read_token.wasm", funcName: "construct_and_read_token", desc: "Step 3: SyntaxToken(head,...) → token.head.kind" },
        { wasmFile: "peek_raw_kind.wasm", funcName: "peek_raw_kind", desc: "Step 4: ParseStream(s) → peek(ps)" },
    ];

    for (const { wasmFile, funcName, desc } of tests) {
        process.stdout.write(`  ${desc}... `);
        const result = await runTest(wasmFile, funcName, "1", 10000);
        if (result.status === "HANG") {
            console.log("HUNG");
        } else if (result.status === "OK") {
            const ok = result.result === 44;
            console.log(`${result.result} ${ok ? "✓ (Integer)" : "✗ WRONG (expected 44=Integer)"}`);
        } else {
            console.log(`${result.status}: ${result.error}`);
        }
    }
}
