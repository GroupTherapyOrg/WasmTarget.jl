#!/usr/bin/env julia
# PURE-324: Test SourceFile construction FROM ParseStream (the actual crash path)
using WasmTarget
using JuliaSyntax

# This is what _parse#75 does: create ParseStream, parse!, then construct SourceFile
# Let's test just the SourceFile construction part

# Test 1: SourceFile from string directly (should work)
function test_sf_from_string(s::String)::Int64
    sf = JuliaSyntax.SourceFile(s)
    return length(sf.line_starts)
end

# Test 2: SourceFile from ParseStream (the crash path)
function test_sf_from_ps(s::String)::Int64
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    # This is what _parse#75 does:
    sf = JuliaSyntax.SourceFile(stream)
    return length(sf.line_starts)
end

# Test 3: Full _parse path (what crashes)
function test_full_parse(s::String)
    JuliaSyntax._parse(:statement, false, Expr, s, 1)
end

println("=== Test 1: SourceFile from String ===")
bytes1 = compile(test_sf_from_string, (String,))
tmpf1 = tempname() * ".wasm"
write(tmpf1, bytes1)
run(`wasm-tools validate --features=gc $tmpf1`)
n1 = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf1 | grep -c '(func'"`, String)))
println("$n1 funcs, $(length(bytes1)) bytes")

cp(tmpf1, joinpath(@__DIR__, "..", "browser", "test_sf_str.wasm"), force=true)
node_test1 = """
import fs from 'fs';
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "test_sf_str.wasm"))');
const mod = await rt.load(w, 'test_sf_from_string');
const s = await rt.jsToWasmString('1');
try {
    const r = mod.exports.test_sf_from_string(s);
    console.log('SF from String PASS:', r);
} catch(e) {
    console.log('SF from String FAIL:', e.message);
    console.log(e.stack.split('\\n').filter(l=>l.includes('wasm')).map(l=>'  '+l.trim()).join('\\n'));
}
"""
tmpjs1 = tempname() * ".mjs"
write(tmpjs1, node_test1)
run(`node $tmpjs1`)

println("\n=== Test 2: SourceFile from ParseStream ===")
bytes2 = compile(test_sf_from_ps, (String,))
tmpf2 = tempname() * ".wasm"
write(tmpf2, bytes2)
run(`wasm-tools validate --features=gc $tmpf2`)
n2 = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf2 | grep -c '(func'"`, String)))
println("$n2 funcs, $(length(bytes2)) bytes")

cp(tmpf2, joinpath(@__DIR__, "..", "browser", "test_sf_ps.wasm"), force=true)
node_test2 = """
import fs from 'fs';
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "test_sf_ps.wasm"))');
const mod = await rt.load(w, 'test_sf_from_ps');
const s = await rt.jsToWasmString('1');
try {
    const r = mod.exports.test_sf_from_ps(s);
    console.log('SF from ParseStream PASS:', r);
} catch(e) {
    console.log('SF from ParseStream FAIL:', e.message);
    console.log(e.stack.split('\\n').filter(l=>l.includes('wasm')).map(l=>'  '+l.trim()).join('\\n'));
}
"""
tmpjs2 = tempname() * ".mjs"
write(tmpjs2, node_test2)
run(`node $tmpjs2`)

println("\n=== Test 3: Full _parse (crashes in full module) ===")
try
    bytes3 = compile(test_full_parse, (String,))
    tmpf3 = tempname() * ".wasm"
    write(tmpf3, bytes3)
    run(`wasm-tools validate --features=gc $tmpf3`)
    n3 = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf3 | grep -c '(func'"`, String)))
    println("$n3 funcs, $(length(bytes3)) bytes")

    cp(tmpf3, joinpath(@__DIR__, "..", "browser", "test_full_parse.wasm"), force=true)
    node_test3 = """
import fs from 'fs';
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "test_full_parse.wasm"))');
const mod = await rt.load(w, 'test_full_parse');
const s = await rt.jsToWasmString('1');
try {
    const r = mod.exports.test_full_parse(s);
    console.log('Full parse PASS:', r);
} catch(e) {
    console.log('Full parse FAIL:', e.message);
    console.log(e.stack.split('\\n').filter(l=>l.includes('wasm')).map(l=>'  '+l.trim()).join('\\n'));
}
"""
    tmpjs3 = tempname() * ".mjs"
    write(tmpjs3, node_test3)
    run(`node $tmpjs3`)
catch e
    println("Compilation error: $e")
end
