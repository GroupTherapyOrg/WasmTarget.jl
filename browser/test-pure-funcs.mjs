/**
 * Test pure i32->i32 functions in parsestmt.wasm.
 */
import { readFile } from "node:fs/promises";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

if (!isMainThread) {
    const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
    const WasmTargetRuntime = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();
    const rt = new WasmTargetRuntime();
    const wasmBytes = await readFile(join(__dirname, "parsestmt.wasm"));
    const parser = await rt.load(wasmBytes, "parsestmt");
    const { funcName, arg } = workerData;
    try {
        const fn = parser.exports[funcName];
        if (!fn) { parentPort.postMessage({ status: "NOT_FOUND" }); process.exit(0); }
        const result = fn(arg);
        parentPort.postMessage({ status: "OK", result });
    } catch (e) {
        parentPort.postMessage({ status: "TRAP", error: (e.message || String(e)).substring(0, 300) });
    }
} else {
    async function runTest(funcName, arg, timeoutMs = 3000) {
        return new Promise((resolve) => {
            const worker = new Worker(fileURLToPath(import.meta.url), {
                workerData: { funcName, arg }
            });
            const timer = setTimeout(() => { worker.terminate(); resolve({ status: "HANG" }); }, timeoutMs);
            worker.on("message", (msg) => { clearTimeout(timer); resolve(msg); });
            worker.on("error", (err) => { clearTimeout(timer); resolve({ status: "ERROR", error: err.message }); });
        });
    }

    console.log("=== parsestmt.wasm Pure Function Tests ===\n");

    // Test all is_* functions with '+'=43, 'x'=120, '1'=49
    const funcs = [
        "is_operator_start_char",
        "is_dottable_operator_start_char",
        "is_identifier_start_char",
        "is_identifier_char",
        "is_never_id_char",
    ];

    const args = [[43, "+"], [120, "x"], [49, "1"], [65, "A"], [95, "_"]];

    for (const funcName of funcs) {
        console.log(`${funcName}:`);
        for (const [code, name] of args) {
            const r = await runTest(funcName, code, 3000);
            const val = r.status === "OK" ? r.result : r.status + (r.error ? `: ${r.error.substring(0, 80)}` : "");
            console.log(`  ('${name}'=${code}) = ${val}`);
        }
    }

    // Also test lex_* functions with i32 args (these likely take a Lexer struct, not a char)
    console.log("\nTesting lex_digit, lex_plus with i32 arg:");
    for (const funcName of ["lex_digit", "lex_plus"]) {
        const r = await runTest(funcName, 49, 3000);
        console.log(`  ${funcName}(49) = ${r.status}${r.error ? `: ${r.error.substring(0, 80)}` : ""}${r.result !== undefined ? ` → ${r.result}` : ""}`);
    }
}
