// Test build_tree phases individually using the runtime
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rc = fs.readFileSync(path.join(__dirname, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

(async () => {
    const rt = new WRT();
    const w = fs.readFileSync(path.join(__dirname, 'parsestmt.wasm'));
    const pa = await rt.load(w, 'parsestmt');
    const ex = pa.exports;

    // List all exported functions
    const funcs = Object.entries(ex).filter(([k,v]) => typeof v === 'function');
    console.log(`Total exports: ${funcs.length}`);
    console.log("Key exports:", funcs.map(([k]) => k).filter(k =>
        k.includes('parse') || k.includes('build') || k.includes('node') ||
        k.includes('ParseStream') || k.includes('Lexer') || k.includes('Source') ||
        k.includes('fixup') || k.includes('untokenize') || k.includes('should')
    ).join(', '));

    console.log("\n=== Test 1: Leaf input '1' ===");
    try {
        const s = await rt.jsToWasmString("1");
        const result = ex.parse_expr_string(s);
        console.log(`  Result: ${result}`);
        console.log(`  Type: ${typeof result}`);
        console.log(`  Is null: ${result === null}`);
        // Try to inspect the result
        if (result !== null) {
            console.log(`  Constructor: ${result?.constructor?.name}`);
        }
    } catch (e) {
        console.log(`  ERROR: ${e.message}`);
    }

    console.log("\n=== Test 2: Non-leaf input '1+1' ===");
    try {
        const s = await rt.jsToWasmString("1+1");
        const result = ex.parse_expr_string(s);
        console.log(`  Result: ${result}`);
    } catch (e) {
        console.log(`  ERROR: ${e.message}`);
    }

    console.log("\n=== Test 3: Call node_to_expr directly ===");
    // node_to_expr takes (RedTreeCursor, SourceFile, Vector{UInt8}, UInt32)
    // The first step is to create a ParseStream and call parse!
    try {
        const s = await rt.jsToWasmString("1");

        // Create ParseStream
        console.log("  Creating ParseStream...");
        const ps = ex.ParseStream(s);
        console.log(`  ParseStream: ${ps} (${typeof ps})`);

        // Call parse!
        console.log("  Calling parse!...");
        const parsed = ex["#parse!#73"](ps);
        console.log(`  parse! result: ${parsed} (${typeof parsed})`);

        // Create SourceFile
        console.log("  Creating SourceFile...");
        // Try both SourceFile variants
        if (ex["#SourceFile#8"]) {
            console.log("  Has #SourceFile#8");
        }
        if (ex["#SourceFile#40"]) {
            console.log("  Has #SourceFile#40");
        }
    } catch (e) {
        console.log(`  ERROR: ${e.message}`);
    }

    console.log("\n=== Test 4: Call build_tree directly ===");
    try {
        const s = await rt.jsToWasmString("1");
        console.log("  Creating ParseStream and parsing...");
        const ps = ex.ParseStream(s);
        const parsed = ex["#parse!#73"](ps);
        console.log(`  parse! returned: ${parsed} (${typeof parsed})`);

        // build_tree takes (i32, ref null 29, ref null 35) based on type 85
        // param0 = i32 (something?), param1 = ParseStream struct, param2 = SourceFile
        // Let's try calling it
        console.log("  Calling build_tree...");
        const tree = ex.build_tree(0, parsed, null);
        console.log(`  build_tree: ${tree} (${typeof tree})`);
    } catch (e) {
        console.log(`  ERROR at build_tree: ${e.message}`);
    }

    console.log("\n=== Test 5: Examine node_to_expr signature ===");
    // node_to_expr is func 18, type 106:
    // (param (ref null 38) (ref null 35) (ref null 6) i32) (result externref)
    // param0: ref null 38 = RedTreeCursor
    // param1: ref null 35 = SourceFile
    // param2: ref null 6  = Vector{UInt8}
    // param3: i32          = UInt32 (offset)
    console.log(`  node_to_expr function exists: ${typeof ex.node_to_expr === 'function'}`);

    console.log("\n=== Test 6: Check fixup_Expr_child ===");
    console.log(`  fixup_Expr_child exists: ${typeof ex.fixup_Expr_child === 'function'}`);

})();
