#!/usr/bin/env julia
# PURE-324: Find the minimum function set that triggers array bounds error
using WasmTarget
using JuliaSyntax

# Stage D: parsestmt(Expr, s) — the full thing
# This adds build_tree and node_to_expr on top of Stage C
function parse_expr_string(s::String)
    JuliaSyntax.parsestmt(Expr, s)
end

println("=== Stage D: parsestmt(Expr, s) ===")
bytes = compile(parse_expr_string, (String,))
println("Stage D: $(length(bytes)) bytes")
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
run(`wasm-tools validate --features=gc $tmpf`)
nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
println("Stage D: $nfuncs functions, validates")

# Write for Node test
write("WasmTarget.jl/browser/parsestmt.wasm", bytes)

# Test
node_test = """
const fs = require('fs');
const rtCode = fs.readFileSync('$(joinpath(dirname(@__DIR__), "WasmTarget.jl", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rtCode + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$(joinpath(dirname(@__DIR__), "WasmTarget.jl", "browser", "parsestmt.wasm"))');
    const mod = await rt.load(w, 'parsestmt');
    const s = await rt.jsToWasmString('1');
    try {
        const r = mod.exports.parse_expr_string(s);
        console.log('Stage D PASS: result=' + r);
    } catch(e) {
        console.log('Stage D FAIL: ' + e.message);
        const lines = e.stack.split('\\n');
        for (const l of lines) { if (l.includes('wasm')) console.log('  ' + l.trim()); }
    }
})();
"""
node_tmpf = tempname() * ".js"
write(node_tmpf, node_test)
node_result = read(`node $node_tmpf`, String)
println(strip(node_result))

# Count func difference from stage C to D
println("\nStage C: 404 funcs → Stage D: $nfuncs funcs")
println("Difference: $(nfuncs - 404) extra functions")
