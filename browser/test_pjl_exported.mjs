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

    // parse_julia_literal is exported with 3 params:
    //   (Vector{UInt8}, SyntaxHead, UnitRange{UInt32})
    // We can't easily construct these Wasm types from JS.
    // But we can use the parse_int_literal export (1 param: String)!

    console.log('--- parse_int_literal tests ---');
    for (const input of ["1", "42", "0", "100", "-1"]) {
        const s = await rt.jsToWasmString(input);
        try {
            const result = e.parse_int_literal(s);
            console.log(`  parse_int_literal("${input}"): ${result}`);
        } catch (err) {
            console.log(`  parse_int_literal("${input}"): FAIL — ${err.message.slice(0, 60)}`);
        }
    }

    // lower_identifier_name is also exported (2 params: Symbol, Kind)
    // But we can't easily construct these types from JS either.

    // Let's try a different approach: run parse_expr_string and see where
    // exactly the crash happens in the call chain. For "1+1":
    // 1. parse! succeeds (verified)
    // 2. build_tree starts
    // 3. node_to_expr is called for toplevel
    // 4. inside node_to_expr, K"block"/K"toplevel" path iterates children
    // 5. For each child, node_to_expr is called recursively
    // 6. For the call node child, parseargs! is called
    // 7. parseargs! iterates call's children: Integer(1), Identifier(+), Integer(1)
    // 8. node_to_expr on one of these children returns nothing
    // 9. @assert fires

    // The crash is at func[45] (parseargs!) at 0xd182d.
    // func[17] (node_to_expr) at 0x1fb95 is the caller.

    // Let's see if we can figure out WHICH iteration of the loop crashes
    // by looking at the WAT around 0xd182d.

    console.log('\n--- Testing individual leaf inputs ---');
    // Test what happens with just "+" as input
    for (const input of ["+", "a", "true", "1.0"]) {
        const s = await rt.jsToWasmString(input);
        try {
            const result = e.parse_expr_string(s);
            console.log(`  parse_expr_string("${input}"): EXECUTES (${typeof result} ${result})`);
        } catch (err) {
            const m = err.stack?.match(/wasm-function\[(\d+)\]:0x([0-9a-f]+)/);
            const loc = m ? `func[${m[1]}] at 0x${m[2]}` : '';
            console.log(`  parse_expr_string("${input}"): FAIL — ${err.message.slice(0, 40)} ${loc}`);
        }
    }

    // Key insight: if "a" crashes at fixup_Expr_child, the Symbol return IS happening
    // but the boxing is wrong. For "1+1", the crash is BEFORE fixup_Expr_child (at parseargs!).
    // This means node_to_expr returns nothing for one of the call's children.
    //
    // The most likely candidate is that the FIRST iteration (Integer at byte 3) succeeds
    // but a LATER iteration (Identifier at byte 2 or Integer at byte 1) fails.

})();
