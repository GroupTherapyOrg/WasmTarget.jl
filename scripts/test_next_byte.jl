#!/usr/bin/env julia
# PURE-324 attempt 18: Isolate next_byte vs last_byte
using WasmTarget
using JuliaSyntax

function do_test(name, f)
    println("\n=== $name ===")
    try
        bytes = compile(f, (String,))
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(`wasm-tools validate --features=gc $tmpf`)
        nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
        println("Compiled: $nfuncs funcs, $(length(bytes)) bytes")

        wasmfile = joinpath(@__DIR__, "..", "browser", "$(name).wasm")
        cp(tmpf, wasmfile, force=true)

        rtpath = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")
        node_test = """
const fs = require('fs');
const rc = fs.readFileSync('$rtpath', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$wasmfile');
    const mod = await rt.load(w, '$name');
    const timer = setTimeout(() => { console.log('$name TIMEOUT'); process.exit(1); }, 5000);
    for (const input of ['1', 'hello']) {
        const s = await rt.jsToWasmString(input);
        try {
            const r = mod.exports.$name(s);
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

# Test A: Return first_byte(stream)
# first_byte = output[1].byte_span + 1
function test_fb(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    fb = JuliaSyntax.first_byte(stream)
    return fb % Int32
end

# Test B: Return next_byte directly (the field)
function test_nb(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    nb = stream.next_byte
    return nb % Int32
end

# Test C: Return last_byte(stream) = next_byte - 1
function test_lb(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    lb = JuliaSyntax.last_byte(stream)
    return lb % Int32
end

# Test D: Return (next_byte - 1) manually
function test_nb_minus_1(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    nb = stream.next_byte
    result = nb - Int64(1)
    return result % Int32
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
for (name, f) in [("test_fb", test_fb), ("test_nb", test_nb), ("test_lb", test_lb), ("test_nb_minus_1", test_nb_minus_1)]
    for input in ["1", "hello"]
        println("$name(\"$input\") = ", f(input))
    end
end

# Compile and test each
do_test("test_fb", test_fb)
do_test("test_nb", test_nb)
do_test("test_lb", test_lb)
do_test("test_nb_minus_1", test_nb_minus_1)
