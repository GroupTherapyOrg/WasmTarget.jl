import { readFileSync } from 'fs';
import { join } from 'path';

const d = new URL('.', import.meta.url).pathname;
const rc = readFileSync(join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const w = readFileSync(join(d, 'parsestmt.wasm'));
const pa = await rt.load(w, 'parsestmt');

// List available exports
const exportNames = Object.keys(pa.exports);
console.log("Total exports:", exportNames.length);
console.log("Key exports:", exportNames.filter(n =>
    n.includes('build') || n.includes('node_to') || n.includes('fixup') ||
    n.includes('parse_expr') || n.includes('_parse') || n.includes('leaf')
));

// Test leaf input "1"
console.log("\n--- Testing leaf input '1' ---");
const s1 = await rt.jsToWasmString("1");
try {
    const r1 = pa.exports.parse_expr_string(s1);
    console.log("parse_expr_string('1'):", typeof r1, r1 === null ? "NULL" : "non-null");
} catch(e) {
    console.log("FAIL:", e.message.substring(0, 100));
}

// Test compound input "1+1"
console.log("\n--- Testing compound input '1+1' ---");
const s2 = await rt.jsToWasmString("1+1");
try {
    const r2 = pa.exports.parse_expr_string(s2);
    console.log("parse_expr_string('1+1'):", typeof r2, r2 === null ? "NULL" : "non-null");
} catch(e) {
    console.log("FAIL:", e.message.substring(0, 100));
}

// Test "(1)" - in native Julia this returns 1 (Int64), same as leaf
console.log("\n--- Testing '(1)' ---");
const s3 = await rt.jsToWasmString("(1)");
try {
    const r3 = pa.exports.parse_expr_string(s3);
    console.log("parse_expr_string('(1)'):", typeof r3, r3 === null ? "NULL" : "non-null");
} catch(e) {
    console.log("FAIL:", e.message.substring(0, 100));
}

// Test "a+b" - compound
console.log("\n--- Testing 'a+b' ---");
const s4 = await rt.jsToWasmString("a+b");
try {
    const r4 = pa.exports.parse_expr_string(s4);
    console.log("parse_expr_string('a+b'):", typeof r4, r4 === null ? "NULL" : "non-null");
} catch(e) {
    console.log("FAIL:", e.message.substring(0, 100));
}
