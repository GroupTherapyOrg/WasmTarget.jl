#!/usr/bin/env julia
# PURE-324 attempt 18: Test initial value of next_byte BEFORE parse!
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

# Test: Return next_byte BEFORE parse! — should be 1
function test_nb_before(s::String)
    stream = JuliaSyntax.ParseStream(s)
    # DO NOT call parse!
    nb = stream.next_byte
    return nb % Int32
end

# Test: Return next_byte from a fresh ParseStream with no parsing
# ParseStream constructor sets next_byte = 1
function test_nb_init(s::String)
    stream = JuliaSyntax.ParseStream(s)
    return stream.next_byte % Int32
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
for (name, f) in [("test_nb_before", test_nb_before), ("test_nb_init", test_nb_init)]
    for input in ["1", "hello"]
        println("$name(\"$input\") = ", f(input))
    end
end

do_test("test_nb_before", test_nb_before)
do_test("test_nb_init", test_nb_init)
