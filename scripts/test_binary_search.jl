#!/usr/bin/env julia
# PURE-324: Binary search for the function that triggers the crash
using WasmTarget
using JuliaSyntax

# Stage C2: parse! returning GreenNode (not converting to Expr)
function parse_green(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    return Int32(stream.stream_position)
end

# Stage D: parsestmt(Expr, s)
function parse_expr_string(s::String)
    JuliaSyntax.parsestmt(Expr, s)
end

# Stage C2 test
println("=== Stage C2: parse! + stream_position ===")
bytes_c2 = compile(parse_green, (String,))
tmpf = tempname() * ".wasm"
write(tmpf, bytes_c2)
run(`wasm-tools validate --features=gc $tmpf`)
nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
println("Stage C2: $(length(bytes_c2)) bytes, $nfuncs funcs")

# Stage D: test from parsestmt
println("\n=== Stage D: parsestmt(Expr, s) ===")
bytes_d = compile(parse_expr_string, (String,))
tmpf_d = tempname() * ".wasm"
write(tmpf_d, bytes_d)
run(`wasm-tools validate --features=gc $tmpf_d`)
nfuncs_d = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf_d | grep -c '(func'"`, String)))
println("Stage D: $(length(bytes_d)) bytes, $nfuncs_d funcs")

# Test both
for (label, tmpf_test) in [("C2", tmpf), ("D", tmpf_d)]
    node_test = """
const fs = require('fs');
const rtCode = fs.readFileSync('WasmTarget.jl/browser/wasmtarget-runtime.js', 'utf-8');
const WRT = new Function(rtCode + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$tmpf_test');
    const mod = await rt.load(w, 'test');
    const exports = Object.keys(mod.exports).filter(k => typeof mod.exports[k] === 'function');
    const fname = exports[0];
    const s = await rt.jsToWasmString('1');
    try {
        const r = mod.exports[fname](s);
        console.log('$label PASS: result=' + r);
    } catch(e) {
        console.log('$label FAIL: ' + e.message);
        const lines = e.stack.split('\\n');
        for (const l of lines) { if (l.includes('wasm')) console.log('  ' + l.trim()); }
    }
})();
"""
    node_tmpf = tempname() * ".js"
    write(node_tmpf, node_test)
    result = read(`node $node_tmpf`, String)
    println(strip(result))
end
