#!/usr/bin/env julia
# PURE-324 attempt 20: Check if parse! produces diagnostics in Wasm
# An error token means some error path was taken

using WasmTarget
using JuliaSyntax

function do_test(name, f, args_types=(String,))
    println("\n=== $name ===")
    try
        bytes = compile(f, args_types)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(Cmd(["wasm-tools", "validate", "--features=gc", tmpf]))
        nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
        println("Compiled: $nfuncs funcs, $(length(bytes)) bytes, VALIDATES")

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

# Test: Check if any_error returns true after parse
function test_any_error(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return JuliaSyntax.any_error(stream) ? Int32(1) : Int32(0)
end

# Test: Return number of diagnostics
function test_diag_count(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return length(stream.diagnostics) % Int32
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
for input in ["1", "hello"]
    println("test_any_error(\"$input\") = ", test_any_error(input))
    println("test_diag_count(\"$input\") = ", test_diag_count(input))
end

do_test("test_any_error", test_any_error)
do_test("test_diag_count", test_diag_count)
