import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rc = fs.readFileSync(path.join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

(async () => {
    const rt = new WRT();
    const w = fs.readFileSync(path.join(__dirname, "parsestmt.wasm"));
    const mod = await rt.load(w, "parsestmt");

    // List all exports
    const exports = Object.keys(mod.exports);
    console.log("Exports:", exports.join(", "));

    // Test "1+1" with detailed error
    const s = await rt.jsToWasmString("1+1");
    try {
        const result = mod.exports.parse_expr_string(s);
        console.log("parse_expr_string('1+1'):", result);
    } catch (e) {
        console.log("CRASH:", e.message);
        if (e.stack) {
            // Parse the stack to find function numbers
            const lines = e.stack.split('\n');
            for (const line of lines.slice(0, 10)) {
                console.log("  ", line.trim());
            }
        }
    }

    // Also test "-1" (negative integer) to confirm it still works
    const s2 = await rt.jsToWasmString("-1");
    try {
        mod.exports.parse_expr_string(s2);
        console.log("parse_expr_string('-1'): EXECUTES");
    } catch (e) {
        console.log("parse_expr_string('-1'): FAIL —", e.message.slice(0, 80));
    }

    // Test "(1)" — parens around integer
    const s3 = await rt.jsToWasmString("(1)");
    try {
        mod.exports.parse_expr_string(s3);
        console.log("parse_expr_string('(1)'): EXECUTES");
    } catch (e) {
        console.log("parse_expr_string('(1)'): FAIL —", e.message.slice(0, 80));
    }

    // Test "a" — simple identifier
    const s4 = await rt.jsToWasmString("a");
    try {
        mod.exports.parse_expr_string(s4);
        console.log("parse_expr_string('a'): EXECUTES");
    } catch (e) {
        console.log("parse_expr_string('a'): FAIL —", e.message.slice(0, 80));
    }
})();
