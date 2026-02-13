#!/usr/bin/env julia
# PURE-324 attempt 8: Progressively test SourceFile chain
# Goal: Find the minimum module size where SourceFile breaks
using WasmTarget
using JuliaSyntax

# Stage A: Just SourceFile constructor (smallest possible)
function sf_test(s::String)
    sf = JuliaSyntax.SourceFile(s)
    return length(sf.line_starts)
end

println("=== Stage A: SourceFile only ===")
bytes_a = compile(sf_test, (String,))
println("Stage A: $(length(bytes_a)) bytes")
tmpf_a = tempname() * ".wasm"
write(tmpf_a, bytes_a)
run(`wasm-tools validate --features=gc $tmpf_a`)
println("Stage A validates")
nfuncs_a = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf_a | grep -c '(func'"`, String)))
println("Stage A: $nfuncs_a functions")

# Test Stage A in Node
node_test = """
const fs = require('fs');
const rtCode = fs.readFileSync('$(joinpath(dirname(@__DIR__), "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rtCode + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$tmpf_a');
    const mod = await rt.load(w, 'test');
    const s = await rt.jsToWasmString('hello');
    try {
        const r = mod.exports.sf_test(s);
        console.log('Stage A PASS: result=' + r);
    } catch(e) {
        console.log('Stage A FAIL: ' + e.message);
        const lines = e.stack.split('\\n');
        for (const l of lines) { if (l.includes('wasm')) console.log('  ' + l.trim()); }
    }
})();
"""
node_tmpf = tempname() * ".js"
write(node_tmpf, node_test)
node_result = read(`node $node_tmpf`, String)
println(strip(node_result))

# Stage B: ParseStream + SourceFile (medium)
function ps_test(s::String)
    stream = JuliaSyntax.ParseStream(s)
    return Int32(1)
end

println("\n=== Stage B: ParseStream (includes SourceFile) ===")
bytes_b = compile(ps_test, (String,))
println("Stage B: $(length(bytes_b)) bytes")
tmpf_b = tempname() * ".wasm"
write(tmpf_b, bytes_b)
run(`wasm-tools validate --features=gc $tmpf_b`)
println("Stage B validates")
nfuncs_b = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf_b | grep -c '(func'"`, String)))
println("Stage B: $nfuncs_b functions")

# Test Stage B
node_test_b = """
const fs = require('fs');
const rtCode = fs.readFileSync('$(joinpath(dirname(@__DIR__), "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rtCode + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$tmpf_b');
    const mod = await rt.load(w, 'test');
    const s = await rt.jsToWasmString('hello');
    try {
        const r = mod.exports.ps_test(s);
        console.log('Stage B PASS: result=' + r);
    } catch(e) {
        console.log('Stage B FAIL: ' + e.message);
        const lines = e.stack.split('\\n');
        for (const l of lines) { if (l.includes('wasm')) console.log('  ' + l.trim()); }
    }
})();
"""
node_tmpf_b = tempname() * ".js"
write(node_tmpf_b, node_test_b)
node_result_b = read(`node $node_tmpf_b`, String)
println(strip(node_result_b))

# Stage C: parse! (the full parse chain)
function parse_test(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    return Int32(1)
end

println("\n=== Stage C: parse! (includes ParseStream + all parse methods) ===")
bytes_c = compile(parse_test, (String,))
println("Stage C: $(length(bytes_c)) bytes")
tmpf_c = tempname() * ".wasm"
write(tmpf_c, bytes_c)
run(`wasm-tools validate --features=gc $tmpf_c`)
println("Stage C validates")
nfuncs_c = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf_c | grep -c '(func'"`, String)))
println("Stage C: $nfuncs_c functions")

# Test Stage C
node_test_c = """
const fs = require('fs');
const rtCode = fs.readFileSync('$(joinpath(dirname(@__DIR__), "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rtCode + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$tmpf_c');
    const mod = await rt.load(w, 'test');
    const s = await rt.jsToWasmString('1');
    try {
        const r = mod.exports.parse_test(s);
        console.log('Stage C PASS: result=' + r);
    } catch(e) {
        console.log('Stage C FAIL: ' + e.message);
        const lines = e.stack.split('\\n');
        for (const l of lines) { if (l.includes('wasm')) console.log('  ' + l.trim()); }
    }
})();
"""
node_tmpf_c = tempname() * ".js"
write(node_tmpf_c, node_test_c)
node_result_c = read(`node $node_tmpf_c`, String)
println(strip(node_result_c))
