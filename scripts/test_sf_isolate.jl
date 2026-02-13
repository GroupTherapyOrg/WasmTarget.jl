#!/usr/bin/env julia
# PURE-324 attempt 11: Isolate SourceFile(stream) crash point
using WasmTarget
using JuliaSyntax

function do_test(name, f, arg_types)
    println("\n=== $name ===")
    try
        bytes = compile(f, arg_types)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(`wasm-tools validate --features=gc $tmpf`)
        nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
        println("Compiled: $nfuncs funcs, $(length(bytes)) bytes")

        wasmfile = joinpath(@__DIR__, "..", "browser", "$(name).wasm")
        cp(tmpf, wasmfile, force=true)

        export_name = string(nameof(f))
        node_test = """
const fs = require('fs');
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$wasmfile');
    const mod = await rt.load(w, '$export_name');
    const timer = setTimeout(() => { console.log('$name TIMEOUT'); process.exit(1); }, 5000);
    for (const input of ['1', 'hello']) {
        const s = await rt.jsToWasmString(input);
        try {
            const r = mod.exports.$export_name(s);
            console.log('$name("' + input + '") = ' + r);
        } catch(e) {
            console.log('$name("' + input + '") FAIL: ' + e.message);
        }
    }
    clearTimeout(timer);
})();
"""
        f_test = tempname() * ".js"
        write(f_test, node_test)
        println(strip(read(`node $f_test`, String)))
    catch e
        println("ERROR: $e")
    end
end

# Test A: first_byte and last_byte from ParseStream
function test_stream_bytes(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    fb = JuliaSyntax.first_byte(stream)
    lb = JuliaSyntax.last_byte(stream)
    return Int32(fb + lb * 1000)  # encode both in one number
end

# Test B: text_root isa String check
function test_textroot_isa(s::String)
    stream = JuliaSyntax.ParseStream(s)
    root = stream.text_root
    if root isa String
        return Int32(1)
    elseif root isa SubString{String}
        return Int32(2)
    else
        return Int32(0)
    end
end

# Test C: thisind on text_root
function test_thisind(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    root = stream.text_root::String
    lb = JuliaSyntax.last_byte(stream)
    ti = thisind(root, lb)
    return Int32(ti)
end

# Test D: SubString creation from text_root
function test_substring_from_root(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    root = stream.text_root::String
    fb = JuliaSyntax.first_byte(stream)
    lb = JuliaSyntax.last_byte(stream)
    ti = thisind(root, lb)
    ss = SubString(root, fb, ti)
    return Int32(ncodeunits(ss))
end

do_test("test_stream_bytes", test_stream_bytes, (String,))
do_test("test_textroot_isa", test_textroot_isa, (String,))
do_test("test_thisind", test_thisind, (String,))
do_test("test_substring_from_root", test_substring_from_root, (String,))
