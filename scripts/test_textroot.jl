#!/usr/bin/env julia
# PURE-324 attempt 11: Test text_root round-trip in ParseStream → SourceFile
using WasmTarget
using JuliaSyntax

# Test 1: Create ParseStream, read text_root, return its length
# This tests the round-trip: String → text_root (Any) → back to String
function test_textroot_len(s::String)
    stream = JuliaSyntax.ParseStream(s)
    # text_root is stored as Any, need to cast back to String
    root = stream.text_root
    if root isa String
        return Int32(ncodeunits(root))
    end
    return Int32(-1)
end

# Test 2: Full SourceFile creation from ParseStream (what parsestmt does)
function test_sf_from_stream(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = JuliaSyntax.SourceFile(stream)
    return Int32(length(source.line_starts))
end

println("=== Test 1: text_root round-trip ===")
try
    bytes = compile(test_textroot_len, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    run(`wasm-tools validate --features=gc $tmpf`)
    nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
    println("Compiled: $nfuncs funcs, $(length(bytes)) bytes")

    wasmfile = joinpath(@__DIR__, "..", "browser", "test_textroot.wasm")
    cp(tmpf, wasmfile, force=true)

    node_test = """
const fs = require('fs');
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$wasmfile');
    const mod = await rt.load(w, 'test_textroot_len');
    for (const input of ['1', 'hello', 'abc']) {
        const s = await rt.jsToWasmString(input);
        try {
            const r = mod.exports.test_textroot_len(s);
            console.log('textroot_len("' + input + '") = ' + r + ' (expected ' + input.length + ')');
        } catch(e) {
            console.log('textroot_len("' + input + '") FAIL: ' + e.message);
        }
    }
})();
"""
    f_test = tempname() * ".js"
    write(f_test, node_test)
    println(read(`node $f_test`, String))
catch e
    println("ERROR: $e")
end

println("\n=== Test 2: SourceFile from ParseStream ===")
try
    bytes2 = compile(test_sf_from_stream, (String,))
    tmpf2 = tempname() * ".wasm"
    write(tmpf2, bytes2)
    run(`wasm-tools validate --features=gc $tmpf2`)
    nfuncs2 = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf2 | grep -c '(func'"`, String)))
    println("Compiled: $nfuncs2 funcs, $(length(bytes2)) bytes")

    wasmfile2 = joinpath(@__DIR__, "..", "browser", "test_sf_stream.wasm")
    cp(tmpf2, wasmfile2, force=true)

    node_test2 = """
const fs = require('fs');
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$wasmfile2');
    const mod = await rt.load(w, 'test_sf_from_stream');
    for (const input of ['1', 'hello', 'a\\nb\\nc']) {
        const s = await rt.jsToWasmString(input);
        try {
            const r = mod.exports.test_sf_from_stream(s);
            console.log('sf_from_stream("' + input + '") = ' + r);
        } catch(e) {
            console.log('sf_from_stream("' + input + '") FAIL: ' + e.message);
        }
    }
})();
"""
    f_test2 = tempname() * ".js"
    write(f_test2, node_test2)
    println(read(`node $f_test2`, String))
catch e
    println("ERROR: $e")
end
