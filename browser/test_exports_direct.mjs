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
    const e = mod.exports;

    // Strategy: call parse_expr_string for "1" (works) and "1+1" (crashes)
    // and compare what happens

    // Test 1: parse_expr_string("1") — SHOULD WORK
    const s1 = await rt.jsToWasmString("1");
    try {
        const r1 = e.parse_expr_string(s1);
        console.log('parse_expr_string("1"):', typeof r1, r1);
    } catch (err) {
        console.log('parse_expr_string("1"): FAIL', err.message);
    }

    // Test 2: parse_expr_string("1+1") — CRASHES
    const s2 = await rt.jsToWasmString("1+1");
    try {
        const r2 = e.parse_expr_string(s2);
        console.log('parse_expr_string("1+1"):', typeof r2, r2);
    } catch (err) {
        console.log('parse_expr_string("1+1"): FAIL', err.message.slice(0, 80));
        // Print stack
        const stack = err.stack.split('\n');
        for (const line of stack.slice(0, 8)) {
            const m = line.match(/wasm-function\[(\d+)\]:0x([0-9a-f]+)/);
            if (m) {
                const funcIdx = parseInt(m[1]);
                const offset = m[2];
                console.log(`  func[${funcIdx}] at 0x${offset}`);
            }
        }
    }

    // Test 3: Check what exports are functions vs other types
    console.log('\n--- Export types ---');
    for (const [name, val] of Object.entries(e)) {
        if (typeof val === 'function') {
            console.log(`  ${name}: function (${val.length} params)`);
        }
    }

    // Test 4: Try calling parse_julia_literal directly
    // parse_julia_literal takes (Vector{UInt8}, SyntaxHead, UnitRange{UInt32})
    // This is tricky because we need to construct the right Wasm types...
    // Actually we can't easily call these functions directly without
    // constructing the right GC struct types.

    // Test 5: Call the parse flow step by step
    // parse_expr_string calls _parse which calls parse! then build_tree
    // Let's try ParseStream construction
    console.log('\n--- Step by step for "1+1" ---');
    try {
        // The #_parse#75 function is the inner function
        // But it takes many params (VersionNumber, etc.) that we can't easily construct
        // Let's just look at what the crash tells us
    } catch (err) {
        console.log('Step-by-step failed:', err.message);
    }

    // Test 6: Try inputs that are just "atoms" vs "expressions"
    console.log('\n--- Atom vs Expression inputs ---');
    const inputs = ["1", "42", "100", "0", "-1", "a", "x", "+", "1+1", "1+2", "a+b"];
    for (const inp of inputs) {
        const s = await rt.jsToWasmString(inp);
        try {
            e.parse_expr_string(s);
            console.log(`  "${inp}": EXECUTES`);
        } catch (err) {
            const m = err.stack?.match(/wasm-function\[(\d+)\]:0x([0-9a-f]+)/);
            const loc = m ? `func[${m[1]}] at 0x${m[2]}` : '';
            console.log(`  "${inp}": FAIL — ${err.message.slice(0, 30)} ${loc}`);
        }
    }
})();
