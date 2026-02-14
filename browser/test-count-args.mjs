import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const runtimeCode = await readFile(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(runtimeCode + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const wasmBytes = await readFile(join(__dirname, "count_parse_args.wasm"));
const mod = await rt.load(wasmBytes, "count");

console.log("Exports:", Object.keys(mod.exports).filter(k => typeof mod.exports[k] === "function").slice(0, 10));

const fn = mod.exports.count_parse_args;
if (!fn) {
    console.log("FAIL: count_parse_args not exported");
    process.exit(1);
}

// Native Julia ground truth:
// "1+1" -> 3 (Expr(:call, :+, 1, 1) has 3 args)
// "a+b" -> 3
// "1+2" -> 3
// "1" -> -1 (not an Expr, returns Int64)
// "x" -> -1 (not an Expr, returns Symbol)

const tests = [
    ["1+1", 3],
    ["a+b", 3],
    ["1+2", 3],
    ["1", -1],
    ["x", -1],
];

let passed = 0, failed = 0;
for (const [input, expected] of tests) {
    const wasmStr = await rt.jsToWasmString(input);
    try {
        const result = fn(wasmStr);
        const resultNum = Number(result);
        if (resultNum === expected) {
            console.log(`  PASS: "${input}" -> ${resultNum} (expected ${expected})`);
            passed++;
        } else {
            console.log(`  FAIL: "${input}" -> ${resultNum} (expected ${expected})`);
            failed++;
        }
    } catch (e) {
        console.log(`  TRAP: "${input}" -> ${e.message}`);
        failed++;
    }
}

console.log(`\nResults: ${passed}/${passed + failed} passed`);
process.exit(failed > 0 ? 1 : 0);
