#!/usr/bin/env julia
# PURE-324: Verify Stage C really works and parse! actually runs
using WasmTarget
using JuliaSyntax

# Exact same as Stage C
function parse_test(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    return Int32(1)
end

println("Compiling parse_test...")
bytes = compile(parse_test, (String,))
println("$(length(bytes)) bytes")
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
run(`wasm-tools validate --features=gc $tmpf`)
nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
println("$nfuncs funcs, validates")

# Node test - check with timeout
node_test = """
const fs = require('fs');
const rtCode = fs.readFileSync('WasmTarget.jl/browser/wasmtarget-runtime.js', 'utf-8');
const WRT = new Function(rtCode + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$tmpf');
    const mod = await rt.load(w, 'test');
    const s = await rt.jsToWasmString('1');

    // Set timeout to detect hangs
    const timer = setTimeout(() => { console.log('TIMEOUT - likely hung'); process.exit(1); }, 5000);

    try {
        const r = mod.exports.parse_test(s);
        clearTimeout(timer);
        console.log('PASS: result=' + r);
    } catch(e) {
        clearTimeout(timer);
        console.log('FAIL: ' + e.message);
        const lines = e.stack.split('\\n');
        for (const l of lines) { if (l.includes('wasm')) console.log('  ' + l.trim()); }
    }
})();
"""
node_tmpf = tempname() * ".js"
write(node_tmpf, node_test)
result = read(`node $node_tmpf`, String)
println(strip(result))
