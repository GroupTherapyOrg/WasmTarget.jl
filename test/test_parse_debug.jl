#!/usr/bin/env julia
# Test: run parse_test with a detailed Node.js error handler to find crash location
using WasmTarget, JuliaSyntax

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function parse_test(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(ps)
    return Int64(1)
end

bytes = compile(parse_test, (String,))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Compiled: $(length(bytes)) bytes")

# Write a Node.js script that catches the error and shows the Wasm function index
js = """
const fs = require('fs');
const runtimeCode = fs.readFileSync('$(escape_string(RUNTIME_JS))', 'utf-8');
const WasmTargetRuntime = new Function(runtimeCode + '\\nreturn WasmTargetRuntime;')();

(async () => {
    const rt = new WasmTargetRuntime();
    const wasmBytes = fs.readFileSync('$(escape_string(tmpf))');
    const mod = await rt.load(wasmBytes, 'test');

    // List exports
    const exports = Object.keys(mod.exports).filter(k => typeof mod.exports[k] === 'function');
    console.log('Exports:', exports.join(', '));

    const func = mod.exports['parse_test'];
    const s = await rt.jsToWasmString('1');

    try {
        const result = func(s);
        console.log('PASS:', result.toString());
    } catch (e) {
        console.log('ERROR:', e.message);
        console.log('Stack:', e.stack);
        // Parse the wasm function indices from the stack trace
        const matches = e.stack.matchAll(/wasm-function\\[(\\d+)\\]/g);
        const funcs = [];
        for (const m of matches) {
            funcs.push(parseInt(m[1]));
        }
        console.log('Wasm function chain:', funcs.join(' -> '));
    }
})();
"""

js_path = tempname() * ".js"
write(js_path, js)
output = read(`node $js_path`, String)
println(output)
