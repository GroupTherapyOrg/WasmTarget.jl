/**
 * Test individual stages of parse_expr_string.
 * parse_expr_string(s) = parsestmt(Expr, s)
 *
 * Internal flow:
 * 1. ParseStream(s) — construct stream with lexer
 * 2. _buffer_lookahead_tokens — tokenize initial tokens
 * 3. parse!(ParseStream, ...) — recursive descent
 * 4. build_tree — construct output AST
 */
import { readFile } from "node:fs/promises";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

if (!isMainThread) {
    // Worker: run a specific function
    const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
    const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();
    const rt = new WasmTargetRuntime();
    const wasmBytes = await readFile(join(__dirname, "parsestmt.wasm"));
    const parser = await rt.load(wasmBytes, "parsestmt");

    try {
        const { testName, input } = workerData;
        const wasmStr = await rt.jsToWasmString(input);

        if (testName === "ParseStream") {
            const result = parser.exports.ParseStream(wasmStr);
            parentPort.postMessage({ status: "OK", result: String(result), type: typeof result });
        } else if (testName === "Lexer") {
            const result = parser.exports.Lexer(wasmStr);
            parentPort.postMessage({ status: "OK", result: String(result), type: typeof result });
        } else if (testName === "next_token") {
            // First need a Lexer, then call next_token
            const lexer = parser.exports.Lexer(wasmStr);
            const token = parser.exports.next_token(lexer);
            parentPort.postMessage({ status: "OK", result: String(token), type: typeof token });
        } else if (testName === "parse_expr_string") {
            const result = parser.exports.parse_expr_string(wasmStr);
            parentPort.postMessage({ status: "OK", result: String(result), type: typeof result });
        } else {
            parentPort.postMessage({ status: "ERROR", error: `Unknown test: ${testName}` });
        }
    } catch (e) {
        parentPort.postMessage({ status: "TRAP", error: (e.message || String(e)).substring(0, 500) });
    }
} else {
    async function runTest(testName, input, timeoutMs = 5000) {
        return new Promise((resolve) => {
            const worker = new Worker(fileURLToPath(import.meta.url), {
                workerData: { testName, input }
            });

            const timer = setTimeout(() => {
                worker.terminate();
                resolve({ status: "HANG" });
            }, timeoutMs);

            worker.on("message", (msg) => {
                clearTimeout(timer);
                resolve(msg);
            });

            worker.on("error", (err) => {
                clearTimeout(timer);
                resolve({ status: "ERROR", error: err.message });
            });

            worker.on("exit", (code) => {
                clearTimeout(timer);
            });
        });
    }

    console.log("=== parsestmt Stage Testing ===\n");

    const tests = [
        ["Lexer", "1"],
        ["ParseStream", "1"],
        ["next_token", "1"],
        ["parse_expr_string", "1"],
    ];

    for (const [name, input] of tests) {
        process.stdout.write(`  ${name}("${input}")... `);
        const result = await runTest(name, input, 5000);
        if (result.status === "HANG") {
            console.log("HUNG (5s timeout)");
        } else if (result.status === "OK") {
            console.log(`OK: ${result.result} (${result.type})`);
        } else {
            console.log(`${result.status}: ${result.error}`);
        }
    }
}
