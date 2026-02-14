// Test build_tree with detailed logging of node_to_expr calls
import { readFile } from 'node:fs/promises';

const wasmBytes = await readFile(new URL('./parsestmt.wasm', import.meta.url));

// Track calls to node_to_expr
let nodeToExprCalls = 0;
let nodeToExprReturns = [];

const { instance } = await WebAssembly.instantiate(wasmBytes, {
    Math: { pow: Math.pow }
});

const exports = instance.exports;

// Test 1: Leaf input "1" - should work
console.log("=== Test: parse_expr_string('1') ===");
try {
    const result1 = exports.parse_expr_string("1");
    console.log("Result:", result1);
    console.log("Type:", typeof result1);
} catch (e) {
    console.log("ERROR:", e.message);
}

console.log();

// Test 2: Non-leaf input "1+1" - crashes
console.log("=== Test: parse_expr_string('1+1') ===");
try {
    const result2 = exports.parse_expr_string("1+1");
    console.log("Result:", result2);
    console.log("Type:", typeof result2);
} catch (e) {
    console.log("ERROR:", e.message);
    // Show stack trace
    console.log("Stack:", e.stack?.split('\n').slice(0, 10).join('\n'));
}

console.log();

// Test 3: Try calling parse phases individually
console.log("=== Test: Manual parse phases ===");
try {
    // Create ParseStream
    const ps = exports.ParseStream("1+1");
    console.log("ParseStream created:", ps, typeof ps);

    // Call parse!
    const parsed = exports["#parse!#73"](ps);
    console.log("parse! completed:", parsed, typeof parsed);

    // Try to examine the parsed output
    // The parse! returns the stream back

    // Try calling SourceFile
    const sf = exports["#SourceFile#40"]("1+1");
    console.log("SourceFile created:", sf, typeof sf);

    // Try build_tree
    console.log("Calling build_tree...");
    const tree = exports.build_tree(ps, sf);
    console.log("build_tree result:", tree, typeof tree);
} catch (e) {
    console.log("ERROR in manual phases:", e.message);
}

console.log();

// Test 4: Try leaf "42" and "x"
console.log("=== Test: Other inputs ===");
for (const input of ["42", "-1", "x", "(1)", "1+2+3"]) {
    try {
        const result = exports.parse_expr_string(input);
        console.log(`  "${input}" => ${result} (${typeof result})`);
    } catch (e) {
        console.log(`  "${input}" => ERROR: ${e.message}`);
    }
}
