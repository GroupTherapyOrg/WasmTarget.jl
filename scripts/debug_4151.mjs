import fs from 'fs';
const bytes = fs.readFileSync('/Users/daleblack/Documents/dev/GroupTherapyOrg/WasmTarget.jl/scripts/debug_4151.wasm');
async function run() {
    try {
        const importObject = { Math: { pow: Math.pow } };
        const wasmModule = await WebAssembly.instantiate(bytes, importObject);
        console.log("Module loaded OK");
        const exports = wasmModule.instance.exports;
        console.log("Exports:", Object.keys(exports).join(", "));
        try {
            const result = exports.test_wsub();
            console.log("test_wsub() =", result);
        } catch (e) {
            console.log("test_wsub TRAP:", e.message);
            console.log("Stack:", e.stack);
        }
    } catch (e) {
        console.log("INSTANTIATION TRAP:", e.message);
        console.log("Stack:", e.stack);
    }
}
run();
